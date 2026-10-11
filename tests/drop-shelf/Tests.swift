import AppKit
import Carbon

func check(_ condition: @autoclosure () throws -> Bool, _ message: String) {
  guard (try? condition()) == true else { print("FAIL: \(message)"); exit(1) }
  print("PASS: \(message)")
}
func rejects(_ message: String, _ operation: () throws -> Void) {
  do { try operation(); check(false, message) } catch { print("PASS: \(message)") }
}
@main struct ShelfTests {
  @MainActor static func main() {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    Task { @MainActor in
      do { try await run(); exit(0) }
      catch { print("FAIL: \(error)"); exit(1) }
    }
    app.run()
  }
  @MainActor static func run() async throws {
    setbuf(stdout, nil)
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.accessory)
    let root = URL(fileURLWithPath: CommandLine.arguments[1]), fm = FileManager.default
    if ProcessInfo.processInfo.environment["DROP_SHELF_TEST_SCOPE"] == "ui" {
      try await runShelfUITests(root: root)
      try await runShelfDragTests(root: root)
      try Data("complete".utf8).write(to: root.appendingPathComponent("qa-complete"))
      return
    }
    let source = root.appendingPathComponent("original.txt")
    let exact = "  café 🙂\n\tlet a = 1;\n  "
    try Data(exact.utf8).write(to: source)
    let store = try ShelfStore(root: root.appendingPathComponent("store"))
    let id = try store.create()
    let file = try ShelfItem.file(source), text = try ShelfItem.text(exact)
    try store.add([file, text], to: id)
    check(store.shelves[0].items.count == 2, "Shelf accepts file references and text")
    check(try Data(contentsOf: source) == Data(exact.utf8), "Adding a file leaves original bytes intact")
    check(text.value == exact, "Text preserves whitespace and Unicode")
    try store.add([file, file, text], to: id)
    check(store.shelves[0].items.count == 2, "Duplicate drops do not duplicate shelf entries")
    let renamed = root.appendingPathComponent("renamed.txt")
    try fm.moveItem(at: source, to: renamed)
    check(file.resolvedURL()?.lastPathComponent == "renamed.txt", "File bookmarks follow Finder-style renames")
    try fm.moveItem(at: renamed, to: source)
    check(try ShelfItem.text("https://example.com/a?q=1").kind == .link, "Web links are recognized")
    check(try ShelfItem.text("file:///etc/passwd").kind == .text, "Text cannot silently turn into a local file reference")
    check(try ShelfItem.text("https://example.com has words").kind == .text, "Ordinary text containing URLs stays text")
    rejects("Empty text is rejected") { _ = try ShelfItem.text("") }
    rejects("Oversized text is bounded") { _ = try ShelfItem.text(String(repeating: "a", count: 1_048_577)) }
    rejects("Missing source file is rejected") { _ = try ShelfItem.file(root.appendingPathComponent("missing")) }
    rejects("Remote file references are rejected") { _ = try ShelfItem.file(URL(string: "https://example.com/test")!) }
    let loaded = try ShelfStore(root: store.root)
    check(loaded.shelves[0].items == store.shelves[0].items, "Shelf content survives restart")
    let mode = try fm.attributesOfItem(atPath: store.stateURL.path)[.posixPermissions] as? NSNumber
    check(mode?.intValue == 0o600, "Shelf state is private to this user")
    let dest = root.appendingPathComponent("output")
    try fm.createDirectory(at: dest, withIntermediateDirectories: true)
    let first = try ShelfFiles.export([file, text], to: dest)
    let second = try ShelfFiles.export([file], to: dest)
    check(first[0].lastPathComponent == "original.txt" && second[0].lastPathComponent == "original 2.txt", "Exports never overwrite existing names")
    check(try Data(contentsOf: first[1]) == Data(exact.utf8), "Text export preserves exact content")
    check(fm.fileExists(atPath: source.path), "Copy to folder retains originals")
    let link = try ShelfItem.text("https://example.com/?a=1&b=2")
    let linkFile = try ShelfFiles.export([link], to: dest)[0]
    let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: linkFile), format: nil) as? [String: String]
    check(plist?["URL"] == link.value, "Link export is a valid webloc")
    let directory = root.appendingPathComponent("directory")
    try fm.createDirectory(at: directory.appendingPathComponent("child"), withIntermediateDirectories: true)
    let folderItem = try ShelfItem.file(directory)
    rejects("Recursive copy into a source descendant is rejected") { _ = try ShelfFiles.export([folderItem], to: directory.appendingPathComponent("child")) }
    let staged = try store.stage(Data([1,2,3]), extension: "png")
    let image = try ShelfItem.file(staged, owned: true, image: true)
    try store.add([image], to: id); store.cleanAttachments()
    check(fm.fileExists(atPath: staged.path), "Referenced owned images are retained")
    try store.update(id) { $0.items.removeAll { $0.id == image.id } }
    store.cleanAttachments()
    check(!fm.fileExists(atPath: staged.path), "Unreferenced generated image is cleaned up")
    check(fm.fileExists(atPath: source.path), "Cleanup never deletes original files")
    rejects("Oversized image is rejected before writing") { _ = try store.stage(Data(count: 20 * 1_048_576 + 1), extension: "png") }
    let before = store.shelves[0].items
    rejects("Shelf item limit is transactional") {
      try store.add(try (0..<201).map { try ShelfItem.text("item \($0)") }, to: id)
    }
    check(store.shelves[0].items == before, "Rejected drop leaves previous items intact")
    try store.update(id) { $0.pinned = true; $0.name = "Pinned fixture" }
    try store.close(id)
    for _ in 0..<12 { let next = try store.create(); try store.close(next) }
    check(store.shelves.filter { $0.closed && !$0.pinned }.count == 10, "History retains ten recent shelves")
    check(store.shelves.contains { $0.id == id && $0.pinned }, "Pinned shelf survives recent-history eviction")
    let brokenRoot = root.appendingPathComponent("broken")
    try fm.createDirectory(at: brokenRoot, withIntermediateDirectories: true)
    try Data("not json".utf8).write(to: brokenRoot.appendingPathComponent("shelves.json"))
    rejects("Corrupt storage fails without replacing user history") { _ = try ShelfStore(root: brokenRoot) }
    // Reproduce a shelf-owned image dragged to a second shelf as a file URL.
    let sharedImage = try store.stage(Data([4, 5, 6]), extension: "png")
    let originalImageShelf = try store.create(), receiverShelf = try store.create()
    try store.add([try .file(sharedImage, owned: true, image: true)], to: originalImageShelf)
    try store.add([try .file(sharedImage)], to: receiverShelf)
    try store.update(originalImageShelf) { $0.items = [] }
    store.cleanAttachments()
    check(fm.fileExists(atPath: sharedImage.path), "Cross-shelf image remains available after removing original reference")

    // Failed disk writes must roll back both halves of a move.
    let splitBefore = store.shelves.map { ($0.id, $0.items) }
    let savedState = try Data(contentsOf: store.stateURL)
    try fm.removeItem(at: store.stateURL)
    try fm.createDirectory(at: store.stateURL, withIntermediateDirectories: true)
    rejects("Failed split rolls back without duplicating or losing items") {
      _ = try store.split(Set(store.shelves.first { $0.id == id }!.items.map(\.id)), from: id)
    }
    check(zip(splitBefore, store.shelves).allSatisfy { $0.0 == $1.id && $0.1 == $1.items }
      && splitBefore.count == store.shelves.count, "Split failure preserves every shelf in memory")
    try fm.removeItem(at: store.stateURL); try savedState.write(to: store.stateURL)
    let movingID = store.shelves.first { $0.id == id }!.items[0].id
    let splitID = try store.split([movingID], from: id)
    let reopenedStore = try ShelfStore(root: store.root)
    check(reopenedStore.shelves.first { $0.id == splitID }?.items.map(\.id) == [movingID]
      && reopenedStore.shelves.first { $0.id == id }?.items.contains { $0.id == movingID } == false,
      "Successful split persists both shelves atomically")
    let protected = try store.stage(Data([7,8]), extension: "png")
    store.cleanAttachments(protecting: [protected])
    check(fm.fileExists(atPath: protected.path), "In-flight export or clipboard reference protects image backing file")
    store.cleanAttachments()
    check(!fm.fileExists(atPath: protected.path), "Backing file is collected after all references are released")
    let limitStore = try ShelfStore(root: root.appendingPathComponent("limits"))
    let limitID = try limitStore.create()
    let twoHundred = try (0..<200).map { try ShelfItem.text("limit item \($0)") }
    try limitStore.add(twoHundred, to: limitID)
    check(limitStore.shelves[0].items.count == 200, "Exactly 200 items fit on a shelf")
    rejects("The 201st distinct item cannot change a full shelf") { try limitStore.add([try .text("overflow")], to: limitID) }
    for _ in 0..<29 { _ = try limitStore.create() }
    rejects("Thirty open shelves enforce the global bound") { _ = try limitStore.create() }
    rejects("Split at the shelf bound preserves the source") { _ = try limitStore.split([twoHundred[0].id], from: limitID) }
    check(limitStore.shelves.first { $0.id == limitID }?.items.count == 200, "Capacity rejection leaves all source references intact")
    try limitStore.close(limitID); try limitStore.update(limitID) { $0.pinned = true }
    rejects("Pinned shelves cannot be evicted for capacity") { _ = try limitStore.create() }
    let evictID = limitStore.shelves[0].id
    try limitStore.close(evictID); _ = try limitStore.create()
    check(limitStore.shelves.count == 30 && !limitStore.shelves.contains { $0.id == evictID }, "Capacity reuses an unpinned recent slot")
    rejects("Invalid colors are rejected before rendering can crash") { try limitStore.update(limitID) { $0.color = -1 } }
    check(limitStore.shelves.first { $0.id == limitID }?.color == 0, "Invalid metadata update rolls back")
    let invalidRoot = root.appendingPathComponent("invalid-metadata")
    try fm.createDirectory(at: invalidRoot, withIntermediateDirectories: true)
    var invalidShelf = Shelf(); invalidShelf.color = -1
    try JSONEncoder().encode([invalidShelf]).write(to: invalidRoot.appendingPathComponent("shelves.json"))
    rejects("Malformed saved metadata cannot reach the UI") { _ = try ShelfStore(root: invalidRoot) }
    let quotaFile = store.attachments.appendingPathComponent(UUID().uuidString).appendingPathExtension("png")
    fm.createFile(atPath: quotaFile.path, contents: nil)
    let quotaHandle = try FileHandle(forWritingTo: quotaFile)
    try quotaHandle.truncate(atOffset: 200 * 1_048_576); try quotaHandle.close()
    rejects("Image storage quota includes existing staged files") { _ = try store.stage(Data([0]), extension: "png") }
    try fm.removeItem(at: quotaFile)
    let textStore = try ShelfStore(root: root.appendingPathComponent("text-quota")), textID = try textStore.create()
    let large = try (0..<17).map { try ShelfItem.text(String($0) + String(repeating: "x", count: 1_048_570)) }
    rejects("Serialized history quota rejects an oversized batch") { try textStore.add(large, to: textID) }
    let quotaReload = try ShelfStore(root: textStore.root)
    check(textStore.shelves[0].items.isEmpty && quotaReload.shelves[0].items.isEmpty,
      "History quota failure preserves empty memory and disk state")
    let strange = root.appendingPathComponent("-quoted ' dollar $ and café.txt")
    try Data(exact.utf8).write(to: strange)
    let zipFolder = root.appendingPathComponent("zip-output"); try fm.createDirectory(at: zipFolder, withIntermediateDirectories: true)
    // run.sh is guarded: these child processes inherit its resource slot, avoiding a nested queue.
    func process(_ command: String, _ args: [String]) throws {
      let p = Process(); p.executableURL = URL(fileURLWithPath: command); p.arguments = args
      p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
      try p.run(); p.waitUntilExit(); if p.terminationStatus != 0 { throw ShelfError("Fixture command failed: \(command)") }
    }
    let zipItems = [try ShelfItem.file(strange), text, link, folderItem]
    let archive = try ShelfFiles.archive(zipItems, to: zipFolder) { input, output in
      try process("/usr/bin/ditto", ["-c", "-k", "--keepParent", input.path, output.path])
    }
    let extracted = root.appendingPathComponent("unzipped")
    try process("/usr/bin/ditto", ["-x", "-k", archive.path, extracted.path])
    check(try Data(contentsOf: extracted.appendingPathComponent("Shelf").appendingPathComponent(strange.lastPathComponent)) == Data(exact.utf8),
      "Real ZIP round trip preserves unusual filenames and exact file bytes")
    check(fm.fileExists(atPath: extracted.appendingPathComponent("Shelf/directory/child").path), "ZIP includes nested folders")
    check(try Data(contentsOf: extracted.appendingPathComponent("Shelf/Text.txt")) == Data(exact.utf8), "ZIP preserves text and whitespace")
    let zipBytes = try Data(contentsOf: archive)
    rejects("Failed compression propagates an error") {
      _ = try ShelfFiles.archive(zipItems, to: zipFolder) { _, _ in throw ShelfError("Injected compression failure") }
    }
    check(try Data(contentsOf: archive) == zipBytes, "Compression failure leaves existing destination archive intact")
    let secondArchive = try ShelfFiles.archive([text], to: zipFolder) { input, output in
      try process("/usr/bin/ditto", ["-c", "-k", "--keepParent", input.path, output.path])
    }
    check(secondArchive.lastPathComponent == "Shelf 2.zip", "ZIP creation never overwrites an existing archive")

    var shake = ShelfShakeDetector()
    for i in 0..<10 { check(!shake.feed(NSPoint(x: i * 20, y: 0), time: Double(i) * 0.03, dragging: true), "Straight drag does not open a shelf") }
    shake = ShelfShakeDetector()
    let points = [0, 45, 0, 45, 0]
    var opened = 0
    for (i, x) in points.enumerated() { if shake.feed(NSPoint(x: x, y: 0), time: Double(i) * 0.04, dragging: true) { opened += 1 } }
    check(opened == 1, "Intentional drag shake opens exactly once")
    check(!shake.feed(NSPoint(x: 45, y: 0), time: 0.3, dragging: true), "Shake cooldown avoids duplicate shelves")
    shake = ShelfShakeDetector()
    for (i, x) in points.enumerated() { check(!shake.feed(NSPoint(x: x, y: 0), time: Double(i), dragging: false), "Mouse movement without drag never opens a shelf") }

    // Headless scope: everything above plus the ingest, import, drag, and reliability regressions.
    // Nothing is shown on screen, activated, or posted, and no global shortcut is registered.
    if ProcessInfo.processInfo.environment["DROP_SHELF_TEST_SCOPE"] == "headless" {
      try await runIngestTests(root: root)
      try await runShelfImportTests(root: root)
      try await runShelfDragTests(root: root)
      try await runShelfReliabilityTests(root: root)
      try Data("complete".utf8).write(to: root.appendingPathComponent("qa-complete"))
      print("Drop Shelf headless QA complete")
      return
    }

    let app = DropShelfApp()
    app.store = store
    let preferencesName = "drop-shelf-qa-\(UUID().uuidString)"
    app.defaults = UserDefaults(suiteName: preferencesName)!
    defer { app.defaults.removePersistentDomain(forName: preferencesName) }

    let uiID = try store.create()
    let controller = ShelfController(app: app, id: uiID)
    app.controllers[uiID] = controller
    controller.present()
    check(!controller.window!.isOpaque && !controller.window!.styleMask.contains(.titled), "Shelf is borderless with transparent window background")
    check(controller.window?.contentView is ShelfDropView, "Shelf uses native translucent material")
    let emptyActions = controller.window!.contentView!.subviews.compactMap { $0 as? ShelfButton }.filter { ["Quick Look (Space)", "Share", "Copy items"].contains($0.toolTip ?? "") }
    check(emptyActions.count == 3 && emptyActions.allSatisfy { !$0.isEnabled }, "Empty shelf disables actions requiring items")
    let board = NSPasteboard(name: .init("drop-shelf-tests-\(UUID().uuidString)"))
    defer { board.releaseGlobally() }
    board.writeObjects([source as NSURL])
    check(controller.ingest(board), "Native drag pasteboard imports a file")
    board.clearContents(); board.setString(exact, forType: .string)
    check(controller.ingest(board), "Native clipboard import preserves text")
    try await waitForShelfImports(app, "file and text import")
    check(controller.items.count == 2, "Multiple drops accumulate in one shelf")
    let paste = controller.writer(text) as? NSPasteboardItem
    check(paste?.string(forType: .string) == exact, "Drag-out writer preserves exact text")
    check(controller.writer(file) is NSURL, "Drag-out files expose native file URLs")
    board.clearContents(); board.setString("unsupported", forType: .init("org.test.unsupported"))
    check(!controller.ingest(board), "Unsupported drop fails without consuming content")
    check(controller.items.count == 2, "Unsupported drop leaves shelf unchanged")
    // Browser-style image drags must land as real image files, never as the image's link.
    let imageShelf = try store.create()
    let imageController = ShelfController(app: app, id: imageShelf)
    app.controllers[imageShelf] = imageController
    func waitForItems(_ count: Int) async throws {
      try await waitForShelfCondition("\(count) image shelf items") {
        imageController.items.count >= count && !app.imports.isBusy
      }
      await app.waitForStore()
    }
    let pixel = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 3, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let jpeg = pixel.representation(using: .jpeg, properties: [:])!
    let png = pixel.representation(using: .png, properties: [:])!
    let tiff = pixel.tiffRepresentation!
    if let port = ProcessInfo.processInfo.environment["SHELF_HTTP_PORT"] {
      try jpeg.write(to: root.appendingPathComponent("http/sunset%20photo.jpg".removingPercentEncoding!))
      try png.write(to: root.appendingPathComponent("http/no-extension"))
      board.clearContents()
      let chrome = NSPasteboardItem()
      chrome.setString("https://example.com/article", forType: .URL)
      chrome.setString("<a href=\"https://example.com/article\"><img alt='x' src=\"http://127.0.0.1:\(port)/sunset%20photo.jpg\"></a>", forType: .html)
      board.writeObjects([chrome])
      check(imageController.ingest(board), "HTML image drag is accepted")
      try await waitForItems(1)
      let saved = imageController.items.last
      check(saved?.kind == .image && saved?.owned == true, "Dragged web image becomes an owned image, not a link")
      check(saved?.label == "sunset photo.jpg" && saved.flatMap { try? Data(contentsOf: $0.resolvedURL()!) } == jpeg,
        "Downloaded image keeps its original bytes and filename")
      let direct = NSPasteboardItem()
      direct.setString("http://127.0.0.1:\(port)/no-extension", forType: .URL)
      board.clearContents(); board.writeObjects([direct])
      check(imageController.ingest(board), "Plain URL without an image extension is accepted")
      try await waitForItems(2)
      check(imageController.items.last?.kind == .link, "A URL that is not recognisably an image stays a link")
      let pngURL = NSPasteboardItem()
      pngURL.setString("http://127.0.0.1:\(port)/missing.png", forType: .URL)
      board.clearContents(); board.writeObjects([pngURL])
      check(imageController.ingest(board), "Broken image URL drop is accepted")
      try await waitForItems(3)
      check(imageController.items.last?.kind == .link, "Failed image download falls back to keeping the link")
    } else {
      print("SKIP: SHELF_HTTP_PORT not set; web image download checks skipped")
    }
    let imageCount = imageController.items.count
    board.clearContents()
    board.setString("data:image/png;base64," + png.base64EncodedString(), forType: .string)
    check(imageController.ingest(board), "data: image drop is accepted")
    try await waitForItems(imageCount + 1)
    check(imageController.items.last?.kind == .image
      && imageController.items.last.flatMap { try? Data(contentsOf: $0.resolvedURL()!) } == png,
      "data: URL image is decoded into a real file")
    board.clearContents(); board.setData(tiff, forType: .tiff)
    check(imageController.ingest(board), "Raw TIFF pixels are accepted")
    try await waitForItems(imageCount + 2)
    let tiffItem = imageController.items.last
    check(tiffItem?.kind == .image && tiffItem?.resolvedURL()?.pathExtension == "png",
      "TIFF pixels are stored as a compact PNG file")
    let imagePaste = tiffItem.flatMap { imageController.writer($0) as? NSPasteboardItem }
    check(imagePaste?.data(forType: .png) != nil && imagePaste?.string(forType: .fileURL) != nil,
      "Dragging a saved image out provides both the file and its pixels")
    board.clearContents(); board.setString("https://example.com/page", forType: .string)
    check(imageController.ingest(board), "Page links are accepted")
    try await waitForItems(imageCount + 3)
    check(imageController.items.last?.kind == .link, "Page links still become links")
    check(ShelfStore.safeFilename("../../etc/passwd", extension: "png") == "-..-etc-passwd.png"
      || !(ShelfStore.safeFilename("../../etc/passwd", extension: "png") ?? "/").contains("/"),
      "Downloaded filenames cannot escape the staging folder")
    store.cleanAttachments()
    check(imageController.items.allSatisfy { $0.resolvedURL().map { fm.fileExists(atPath: $0.path) } ?? true },
      "Cleanup retains files inside named image folders")
    imageController.window?.close()
    app.controllers[imageShelf] = nil
    try store.close(imageShelf)
    controller.message = nil
    for _ in 0..<100 { _ = try controller.preparePreviewURLs() }
    check(try fm.contentsOfDirectory(atPath: controller.previewDirectory!.path).count == 1,
      "One hundred previews reuse a single text cache file")
    check(try controller.preparePreviewURLs().allSatisfy { fm.fileExists(atPath: $0.path) }, "Every returned preview URL points to an existing file")
    let previewPath = controller.previewDirectory!
    controller.closePreview()
    check(!fm.fileExists(atPath: previewPath.path), "Closing preview releases its temporary files")
    controller.select(controller.items[0].id, extend: false)
    check(controller.chosen.count == 1, "Selection limits actions to selected items")
    controller.select(controller.items[1].id, extend: true)
    check(controller.chosen.count == 2, "Command selection supports multiple items")
    controller.selected = []
    controller.render()
    try snapshot(controller, to: root.appendingPathComponent("compact.png"))
    controller.expanded = true; controller.render()
    try snapshot(controller, to: root.appendingPathComponent("expanded.png"))
    let selectedID = controller.items[0].id
    controller.select(selectedID, extend: false); controller.removeAction()
    try await waitForShelfCondition("selection removal") { controller.items.count == 1 }
    await app.waitForStore()
    check(controller.items.count == 1 && fm.fileExists(atPath: source.path), "Remove from shelf does not delete source file")
    controller.window?.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    try await Task.sleep(nanoseconds: 200_000_000)
    check(controller.window?.isKeyWindow == true, "Borderless shelf receives keyboard focus")
    let oldChange = NSPasteboard.general.changeCount
    let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: controller.window!.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 53)!
    _ = app.handleKey(event)
    check(NSPasteboard.general.changeCount == oldChange, "Escape leaves the user's clipboard untouched")
    try await waitForShelfCondition("Escape shelf closure") { store.shelves.first { $0.id == uiID }?.closed == true }
    await app.waitForStore()
    check(store.shelves.first { $0.id == uiID }?.closed == true, "Escape closes shelf into recent history")
    app.showSettings()
    app.recordShortcut()
    app.settings?.close()
    check(!app.recording, "Closing Settings cancels shortcut recording")
    let modifiers = UInt32(controlKey | optionKey | shiftKey)
    var reserved: EventHotKeyRef?
    var reservedCode: UInt32 = 0
    for code in [UInt32(105), 107, 113, 106, 64] {
      if RegisterEventHotKey(code, modifiers, EventHotKeyID(signature: 0x51415453, id: 2), GetApplicationEventTarget(), 0, &reserved) == noErr {
        reservedCode = code; break
      }
    }
    check(reserved != nil, "Fixture reserves an unused key for a real shortcut-conflict test")
    defer { if let reserved { UnregisterEventHotKey(reserved) }; if let hotkey = app.hotkey { UnregisterEventHotKey(hotkey) } }
    for code in [UInt32(105), 107, 113, 106, 64] where code != reservedCode {
      app.defaults.set(Int(code), forKey: "key"); app.defaults.set(Int(modifiers), forKey: "modifiers")
      app.registerShortcut()
      if app.hotkey != nil { break }
    }
    check(app.hotkey != nil, "Fixture has a working previous shortcut")
    let oldCode = app.defaults.integer(forKey: "key")
    app.recording = true
    let conflict = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.control, .option, .shift], timestamp: 0,
      windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: UInt16(reservedCode))!
    _ = app.handleKey(conflict)
    check(app.defaults.integer(forKey: "key") == oldCode && app.hotkey != nil,
      "Conflicting shortcut keeps the previous shortcut registered and saved")
    if let hotkey = app.hotkey { UnregisterEventHotKey(hotkey); app.hotkey = nil }
    try await runIngestTests(root: root)
    try await runShelfImportTests(root: root)
    try await runShelfUITests(root: root)
    try await runShelfDragTests(root: root)
    try await runShelfReliabilityTests(root: root)
    if let duration = Int(ProcessInfo.processInfo.environment["DROP_SHELF_SOAK_SECONDS"] ?? ""), duration > 0 {
      let stressID = try store.create()
      try store.add(twoHundred, to: stressID)
      let stress = ShelfController(app: app, id: stressID)
      func memory() -> UInt64 {
        var info = rusage_info_v2()
        let status = withUnsafeMutablePointer(to: &info) { p in
          p.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_V2, $0) }
        }
        return status == 0 ? info.ri_phys_footprint : 0
      }
      var peak = memory(), baseline: UInt64 = 0, worst: TimeInterval = 0
      for cycle in 0..<duration {
        let start = Date()
        autoreleasepool {
          stress.expanded = cycle % 2 == 0
          stress.render()
          stress.selected = Set(twoHundred.prefix(cycle % 200 + 1).map(\.id))
        }
        worst = max(worst, Date().timeIntervalSince(start))
        try await Task.sleep(nanoseconds: 1_000_000_000)
        peak = max(peak, memory())
        if cycle == 5 { baseline = memory() }
      }
      let final = memory()
      print("SOAK seconds=\(duration) items=200 peak_footprint_MiB=\(peak / 1_048_576) final_footprint_MiB=\(final / 1_048_576) growth_MiB=\(final > baseline ? (final - baseline) / 1_048_576 : 0) worst_render_ms=\(worst * 1000)")
      check(final <= baseline + 80 * 1_048_576, "Repeated maximum-size shelf rendering has bounded memory growth")
      check(worst < 0.15, "Maximum-size shelf renders within 150 ms during repeated use")
      stress.closePreview(); stress.window?.close()
    }
    try Data("complete".utf8).write(to: root.appendingPathComponent("qa-complete"))
    print("Drop Shelf QA complete")
  }
  @MainActor static func snapshot(_ controller: ShelfController, to url: URL) throws {
    guard let view = controller.window?.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw ShelfError("Could not snapshot shelf") }
    view.layoutSubtreeIfNeeded(); view.cacheDisplay(in: view.bounds, to: rep)
    try rep.representation(using: .png, properties: [:])?.write(to: url)
  }
}
