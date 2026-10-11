import AppKit

private final class ShelfDragPixelProbe: NSObject, NSPasteboardItemDataProvider {
  private let lock = NSLock()
  private var count = 0
  let data: Data
  init(_ data: Data) { self.data = data }
  var reads: Int { lock.lock(); defer { lock.unlock() }; return count }
  func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
    lock.lock(); count += 1; lock.unlock()
    item.setData(data, forType: type)
  }
}

@MainActor func runShelfDragTests(root: URL) async throws {
  let fm = FileManager.default
  func sameFile(_ actual: URL?, _ expected: URL) -> Bool {
    actual?.resolvingSymlinksInPath().standardizedFileURL == expected.resolvingSymlinksInPath().standardizedFileURL
  }
  let folder = root.appendingPathComponent("drag-regressions")
  try fm.createDirectory(at: folder, withIntermediateDirectories: true)
  let store = try ShelfStore(root: folder.appendingPathComponent("store"))
  let sourceID = try store.create(), destinationID = try store.create()
  let app = DropShelfApp()
  app.store = store
  // Cleanup consults a private stand-in for the clipboard, never the user's.
  app.generalPasteboard = NSPasteboard(name: .init("drop-shelf-drag-general-\(UUID().uuidString)"))
  defer { app.generalPasteboard.releaseGlobally() }
  let source = ShelfController(app: app, id: sourceID), destination = ShelfController(app: app, id: destinationID)
  app.controllers[sourceID] = source; app.controllers[destinationID] = destination
  defer {
    for controller in app.allControllers { controller.closePreview(); controller.window?.orderOut(nil); controller.window?.close() }
    app.controllers.removeAll(); app.replicas.removeAll()
  }
  let board = NSPasteboard(name: .init("drop-shelf-drag-\(UUID().uuidString)"))
  defer { board.releaseGlobally() }
  let userClipboardChange = NSPasteboard.general.changeCount

  let pixel = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 3, bitsPerSample: 8,
    samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
  let png = pixel.representation(using: .png, properties: [:])!
  let imageURL = folder.appendingPathComponent("finder-image.png")
  try png.write(to: imageURL)
  let fileImage = try ShelfItem.file(imageURL)
  let documentURL = folder.appendingPathComponent("document.txt")
  let documentBytes = Data("original file bytes".utf8)
  try documentBytes.write(to: documentURL)
  let file = try ShelfItem.file(documentURL)
  let exact = "  café 🙂\n\tselection text  "
  let text = try ShelfItem.text(exact)
  let link = try ShelfItem.text(" https://example.com/path?a=1&b=2 \n")
  try store.add([fileImage, file, text, link], to: sourceID)

  let imageWriter = source.writer(fileImage) as? NSPasteboardItem
  let outgoingImageURL = imageWriter?.string(forType: .fileURL).flatMap(URL.init(string:))
  check(fileImage.kind == .file && sameFile(outgoingImageURL, imageURL),
    "Finder images retain native file URLs when dragged out")
  check(imageWriter?.data(forType: .png) == png,
    "Image file references advertise original pixels independently of shelf item kind")
  check(source.writer(file) is NSURL, "Ordinary files keep native URL pasteboard writers")
  let textWriter = source.writer(text) as? NSPasteboardItem
  let linkWriter = source.writer(link) as? NSPasteboardItem
  check(textWriter?.string(forType: .string) == exact, "Outgoing text preserves exact Unicode and whitespace")
  check(linkWriter?.string(forType: .URL) == "https://example.com/path?a=1&b=2"
    && linkWriter?.string(forType: .string) == link.value,
    "Outgoing links expose both a usable URL and their original text")
  board.writeObjects([textWriter!, linkWriter!])
  check(board.string(forType: .string) == exact + "\n" + link.value,
    "A destination reading plain text receives all copied text and link items")

  let lazy = source.writer(fileImage) as? NSPasteboardItem
  let renamed = folder.appendingPathComponent("finder-image-renamed.png")
  try fm.moveItem(at: imageURL, to: renamed)
  check(lazy?.data(forType: .png) == nil,
    "Outgoing image bytes are read lazily only when the destination requests them")
  try fm.moveItem(at: renamed, to: imageURL)

  let probe = ShelfDragPixelProbe(png)
  let probed = NSPasteboardItem()
  probed.setString(imageURL.absoluteString, forType: .fileURL)
  probed.setDataProvider(probe, forTypes: [.png])
  board.clearContents(); board.writeObjects([probed])
  let fastEntries = try ShelfIngest.entries(from: board, preferFileReferences: true)
  check(sameFile(fastEntries.first?.file, imageURL) && fastEntries.first?.imageData == nil && probe.reads == 0,
    "A trusted shelf-to-shelf drag uses file references without materializing image pixels")
  let externalEntries = try ShelfIngest.entries(from: board)
  check(externalEntries.first?.imageData?.0 == png && probe.reads == 1,
    "External browser-style file URLs still snapshot fallback pixels while the pasteboard is valid")

  let ownedURL = try store.stage(png, extension: "png", name: "Collected image")
  let owned = try ShelfItem.file(ownedURL, owned: true, image: true)
  try store.add([owned], to: sourceID)
  board.clearContents(); board.writeObjects([source.writer(owned)!])
  check(destination.ingest(board, preferFileReferences: true), "A collected image can be dropped onto a second shelf")
  try await waitForShelfImports(app, "image shelf-to-shelf round trip")
  guard let roundTrip = destination.items.first else { throw ShelfError("Missing round-trip image fixture") }
  let returned = destination.writer(roundTrip) as? NSPasteboardItem
  let returnedURL = returned?.string(forType: .fileURL).flatMap(URL.init(string:))
  check(roundTrip.kind == .file && sameFile(returnedURL, ownedURL)
    && returned?.data(forType: .png) == png,
    "Shelf-to-shelf image references remain usable by both file and image-only destinations")
  check(try Data(contentsOf: ownedURL) == png && Data(contentsOf: documentURL) == documentBytes,
    "Outgoing preparation and shelf-to-shelf copies preserve original file bytes")

  let missingURL = folder.appendingPathComponent("missing.txt")
  try Data("gone".utf8).write(to: missingURL)
  let missing = try ShelfItem.file(missingURL)
  try await app.withStore { try $0.add([missing], to: sourceID) }
  try fm.removeItem(at: missingURL)
  source.selected = [file.id, text.id, missing.id]
  source.copyItems(to: board)
  check(board.pasteboardItems?.count == 2 && board.string(forType: .string) == exact,
    "Mixed copy retains every available file and text item")
  check(source.summaryLabel.stringValue.contains("Copied 2 items") && source.summaryLabel.stringValue.contains("1 unavailable"),
    "Partial copy clearly reports unavailable source files")
  source.selected = [missing.id]
  let privateChange = board.changeCount
  source.copyItems(to: board)
  check(board.changeCount == privateChange && source.summaryLabel.stringValue.contains("removed"),
    "An all-missing copy preserves the existing clipboard contents and shows its failure")

  let leaseURL = try await app.withStore { try $0.stage(png, extension: "png", name: "Active drag") }
  let lease = UUID()
  app.activeDragURLs[lease] = [leaseURL]
  check(app.hasActiveWork, "An outgoing drag keeps the helper alive until its session finishes")
  app.cleanAttachments()
  await Task.yield(); await app.waitForStore()
  check(fm.fileExists(atPath: leaseURL.path), "An active outgoing drag protects its generated backing file from cleanup")
  app.activeDragURLs.removeValue(forKey: lease)
  app.cleanAttachments()
  try await waitForShelfCondition("released outgoing drag cleanup") { !fm.fileExists(atPath: leaseURL.path) }
  await app.waitForStore()
  check(!fm.fileExists(atPath: leaseURL.path), "Finishing a drag releases files with no remaining references")

  let transferURL = try await app.withStore { try $0.stage(png, extension: "png", name: "Pending transfer") }
  let gate = ShelfImportGate()
  app.imports.resolver = { try await gate.resolve($0) }
  let transferLease = UUID()
  app.activeDragURLs[transferLease] = [transferURL]
  try app.imports.accept(entries: [.init(file: transferURL, text: "pending-transfer")], to: destinationID)
  try await waitForShelfCondition("pending file transfer resolver") { gate.keys == ["pending-transfer"] }
  app.activeDragURLs.removeValue(forKey: transferLease)
  check(app.imports.protectedFileURLs.contains { sameFile($0, transferURL) },
    "An accepted shelf transfer protects its file after the originating drag ends")
  app.cleanAttachments()
  await Task.yield(); await app.waitForStore()
  check(fm.fileExists(atPath: transferURL.path), "Pending shelf imports retain their source files during cleanup")
  gate.finish("pending-transfer", items: [try ShelfItem.file(transferURL)])
  try await waitForShelfImports(app, "pending file transfer completion")
  app.imports.resolver = nil
  check(destination.items.contains { sameFile($0.resolvedURL(), transferURL) } && fm.fileExists(atPath: transferURL.path),
    "A delayed shelf transfer commits the original file after its drag lease is released")

  check(NSPasteboard.general.changeCount == userClipboardChange,
    "Cross-app writer and mixed-copy regressions leave the user's clipboard unchanged")
}
