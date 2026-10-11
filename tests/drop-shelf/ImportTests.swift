import AppKit

@MainActor func waitForShelfCondition(_ description: String, timeout: TimeInterval = 5,
  _ condition: () -> Bool) async throws {
  let deadline = Date().addingTimeInterval(timeout)
  while !condition() {
    guard Date() < deadline else { throw ShelfError("Timed out waiting for \(description)") }
    try await Task.sleep(nanoseconds: 5_000_000)
  }
}

@MainActor func waitForShelfImports(_ app: DropShelfApp, _ description: String) async throws {
  try await waitForShelfCondition(description) { !app.imports.isBusy }
  await app.waitForStore()
}

@MainActor final class ShelfImportGate {
  private var waiting: [String: CheckedContinuation<ShelfImportCoordinator.Resolution, Error>] = [:]
  private(set) var peak = 0
  var keys: Set<String> { Set(waiting.keys) }
  func resolve(_ entry: ShelfIngest.Entry) async throws -> ShelfImportCoordinator.Resolution {
    guard let key = entry.text else { throw ShelfError("Missing import fixture key") }
    return try await withCheckedThrowingContinuation { continuation in
      waiting[key] = continuation
      peak = max(peak, waiting.count)
    }
  }
  func finish(_ key: String, items: [ShelfItem], warning: String? = nil) {
    waiting.removeValue(forKey: key)?.resume(returning: .init(items: items, warning: warning))
  }
  func fail(_ key: String) {
    waiting.removeValue(forKey: key)?.resume(throwing: ShelfError("Injected import failure: \(key)"))
  }
}

private final class ShelfImportMixedPromise: NSFilePromiseReceiver {
  let image: Data
  init(image: Data) { self.image = image; super.init() }
  required init?(pasteboardPropertyList propertyList: Any, ofType type: NSPasteboard.PasteboardType) { return nil }
  override var fileNames: [String] { ["valid.png", "corrupt.png"] }
  override var fileTypes: [String] { ["public.png", "public.png"] }
  override func receivePromisedFiles(atDestination destinationDir: URL, options: [AnyHashable: Any] = [:],
    operationQueue: OperationQueue, reader: @escaping (URL, Error?) -> Void) {
    let deliveries = [("valid.png", image), ("corrupt.png", Data("not image bytes".utf8))]
    for (name, data) in deliveries {
      operationQueue.addOperation {
        let url = destinationDir.appendingPathComponent(name)
        do { try data.write(to: url); reader(url, nil) }
        catch { reader(url, error) }
      }
    }
  }
}

@MainActor func runShelfImportTests(root: URL) async throws {
  let fm = FileManager.default
  // Cleanup after each commit consults this stand-in instead of the user's clipboard.
  let clipboard = NSPasteboard(name: .init("drop-shelf-import-general-\(UUID().uuidString)"))
  defer { clipboard.releaseGlobally() }
  func fixture(_ name: String) throws -> (DropShelfApp, ShelfStore, UUID) {
    let store = try ShelfStore(root: root.appendingPathComponent("imports-\(name)"))
    let id = try store.create(), app = DropShelfApp()
    app.store = store; app.generalPasteboard = clipboard
    return (app, store, id)
  }
  func entry(_ key: String, image: Bool = false) -> ShelfIngest.Entry {
    var result = ShelfIngest.Entry()
    result.text = key
    if image { result.imageURL = URL(string: "https://fixtures.invalid/\(key).png")! }
    return result
  }

  do {
    let (app, store, id) = try fixture("serialized-worker")
    let started = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
    let firstItem = try ShelfItem.text("first queued write"), secondItem = try ShelfItem.text("second queued write")
    let first = Task { @MainActor in
      try await app.withStore { snapshot in
        started.signal()
        guard release.wait(timeout: .now() + 2) == .success else { throw ShelfError("UI failed to release background worker") }
        try snapshot.add([firstItem], to: id)
        return !Thread.isMainThread
      }
    }
    defer { release.signal() }
    try await waitForShelfCondition("background worker start") { started.wait(timeout: .now()) == .success }
    let second = Task { @MainActor in
      try await app.withStore { snapshot in
        try snapshot.add([secondItem], to: id)
        return !Thread.isMainThread
      }
    }
    try await waitForShelfCondition("second queued transaction") { app.storeOperations == 2 }
    var heartbeat = false
    Task { @MainActor in heartbeat = true }
    try await waitForShelfCondition("UI heartbeat while file worker is blocked") { heartbeat }
    check(store.shelves.first { $0.id == id }?.items.isEmpty == true,
      "UI heartbeat continues while background store work is still blocked")
    release.signal()
    let firstOffMain = try await first.value, secondOffMain = try await second.value
    check(firstOffMain && secondOffMain, "Store transactions run off the main thread")
    check(store.shelves.first { $0.id == id }?.items.map(\.value) == [firstItem.value, secondItem.value],
      "Two concurrent store writes publish in order without losing either update")
    let rejectedItem = try ShelfItem.text("must roll back"), recoveredItem = try ShelfItem.text("after failed write")
    let failed = Task { @MainActor in
      try await app.withStore { snapshot in
        try snapshot.update(id) { shelf in
          shelf.items.append(rejectedItem)
          throw ShelfError("Injected worker transaction failure")
        }
      }
    }
    let recovered = Task { @MainActor in try await app.withStore { try $0.add([recoveredItem], to: id) } }
    do { try await failed.value; check(false, "Injected worker transaction is rejected") }
    catch { check(error.localizedDescription.contains("Injected worker transaction"), "Injected worker transaction is rejected") }
    try await recovered.value
    await app.waitForStore()
    let reload = try ShelfStore(root: store.root)
    check(reload.shelves.first { $0.id == id }?.items.map(\.value) == [firstItem.value, secondItem.value, recoveredItem.value],
      "Failed store work rolls back and does not poison the next queued write")
  }

  // The app owns accepted work after the original controller/window has gone away.
  do {
    let (app, store, id) = try fixture("lifetime")
    let gate = ShelfImportGate()
    app.imports.resolver = { try await gate.resolve($0) }
    var original: ShelfController? = ShelfController(app: app, id: id)
    weak var retired = original
    app.controllers[id] = original
    try app.imports.accept(entries: [entry("held-image", image: true)], to: id)
    check(app.imports.isBusy && app.imports.pendingCount(for: id) == 1,
      "Accepted drop immediately reserves its item and marks the app busy")
    check(app.imports.message(for: id)?.localizedCaseInsensitiveContains("adding") == true,
      "Accepted image immediately exposes progress before resolution starts")
    try await waitForShelfCondition("delayed image resolver") { gate.keys.contains("held-image") }
    original?.window?.orderOut(nil)
    app.controllers[id] = nil
    original = nil
    try await waitForShelfCondition("original shelf controller release") { retired == nil }
    try await app.withStore { store in
      try store.close(id)
      for _ in 0..<12 { let recent = try store.create(); try store.close(recent) }
    }
    check(store.shelves.contains { $0.id == id && $0.closed },
      "Closed shelf with a pending import survives recent-history eviction")
    try await app.withStore { try $0.update(id) { $0.closed = false } }
    let reopened = ShelfController(app: app, id: id)
    app.controllers[id] = reopened
    check(reopened.pendingImages == 1, "Reopened shelf shows the original pending import")
    gate.finish("held-image", items: [try .text("arrived after reopening")])
    try await waitForShelfImports(app, "closed and reopened shelf import")
    check(reopened.items.map(\.value) == ["arrived after reopening"],
      "Accepted import lands once on its original shelf after reopening")
    let reload = try ShelfStore(root: store.root)
    check(reload.shelves.first { $0.id == id }?.items.map(\.value) == ["arrived after reopening"],
      "Import accepted before closing is persisted after delivery")
    reopened.window?.close()
  }

  // Reserve capacity before awaiting delivery so overlapping drops cannot overbook it.
  do {
    let (app, store, id) = try fixture("capacity")
    try store.add(try (0..<199).map { try .text("existing \($0)") }, to: id)
    let gate = ShelfImportGate()
    app.imports.resolver = { try await gate.resolve($0) }
    try app.imports.accept(entries: [entry("last-slot")], to: id)
    rejects("A pending import reserves the last shelf slot") {
      try app.imports.accept(entries: [entry("overbooked")], to: id)
    }
    check(app.imports.pendingCount(for: id) == 1,
      "Rejected overlapping drop does not add a phantom reservation")
    try await waitForShelfCondition("last slot resolver") { gate.keys.contains("last-slot") }
    gate.finish("last-slot", items: [try .text("last-slot")])
    try await waitForShelfImports(app, "last slot persistence")
    check(store.shelves.first { $0.id == id }?.items.count == 200 && app.imports.pendingCount(for: id) == 0,
      "Successful delivery fills exactly the reserved slot and releases its reservation")
    rejects("Unsupported entries cannot create pending work") {
      try app.imports.accept(entries: [ShelfIngest.Entry()], to: id)
    }
    check(!app.imports.isBusy, "Unsupported input leaves the import coordinator idle")
  }

  // Both entries within a drop and overlapping drops retain acceptance order.
  do {
    let (app, store, id) = try fixture("ordering")
    let gate = ShelfImportGate()
    app.imports.resolver = { try await gate.resolve($0) }
    try app.imports.accept(entries: [entry("first"), entry("second")], to: id)
    try app.imports.accept(entries: [entry("third")], to: id)
    try await waitForShelfCondition("first two concurrent imports") { gate.keys == ["first", "second"] }
    gate.finish("second", items: [try .text("second")])
    try await waitForShelfCondition("queued third import") { gate.keys.contains("third") }
    gate.finish("third", items: [try .text("third")])
    try await Task.sleep(nanoseconds: 10_000_000)
    check(store.shelves.first { $0.id == id }?.items.isEmpty == true,
      "Later drop waits for the earlier accepted batch before committing")
    gate.finish("first", items: [try .text("first")])
    try await waitForShelfImports(app, "ordered import commits")
    check(store.shelves.first { $0.id == id }?.items.map(\.value) == ["first", "second", "third"],
      "Out-of-order deliveries preserve item and overlapping-drop order")
    check(gate.peak <= 2, "Import processing never exceeds two concurrent jobs")
  }

  do {
    let (app, store, id) = try fixture("partial")
    let gate = ShelfImportGate()
    app.imports.resolver = { try await gate.resolve($0) }
    try app.imports.accept(entries: [entry("broken"), entry("good")], to: id)
    try await waitForShelfCondition("partial failure fixtures") { gate.keys.count == 2 }
    gate.fail("broken")
    gate.finish("good", items: [try .text("preserved success")])
    try await waitForShelfImports(app, "partial success persistence")
    check(store.shelves.first { $0.id == id }?.items.map(\.value) == ["preserved success"],
      "One failed entry does not discard successfully imported entries")
    check(app.imports.message(for: id)?.contains("Injected import failure") == true,
      "Later successful entry does not clear partial-failure feedback")
    check(app.imports.pendingCount(for: id) == 0,
      "Partial failure releases successful and failed capacity reservations")
  }

  // A disk failure must not publish success or strand a capacity reservation.
  do {
    let (app, store, id) = try fixture("persistence")
    let gate = ShelfImportGate()
    app.imports.resolver = { try await gate.resolve($0) }
    let original = root.appendingPathComponent("import-original.txt")
    try Data("original bytes".utf8).write(to: original)
    let savedState = try Data(contentsOf: store.stateURL)
    try app.imports.accept(entries: [entry("disk-failure")], to: id)
    try await waitForShelfCondition("failed persistence resolver") { gate.keys.contains("disk-failure") }
    try fm.removeItem(at: store.stateURL)
    try fm.createDirectory(at: store.stateURL, withIntermediateDirectories: false)
    gate.finish("disk-failure", items: [try .file(original)])
    try await waitForShelfImports(app, "failed persistence rollback")
    check(store.shelves.first { $0.id == id }?.items.isEmpty == true,
      "Failed import persistence leaves the visible shelf unchanged")
    check(app.imports.pendingCount(for: id) == 0 && app.imports.message(for: id) != nil,
      "Failed persistence releases capacity and reports the error")
    check(try Data(contentsOf: original) == Data("original bytes".utf8),
      "Import persistence failure never changes the original file")
    try fm.removeItem(at: store.stateURL)
    try savedState.write(to: store.stateURL)
    try app.imports.accept(entries: [entry("disk-failure")], to: id)
    try await waitForShelfCondition("retry resolver") { gate.keys.contains("disk-failure") }
    gate.finish("disk-failure", items: [try .file(original)])
    try await waitForShelfImports(app, "retry persistence")
    let reload = try ShelfStore(root: store.root)
    check(reload.shelves.first { $0.id == id }?.items.count == 1,
      "An import can be retried successfully after persistence recovers")
  }

  let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 3, pixelsHigh: 2,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
  let png = bitmap.representation(using: .png, properties: [:])!
  do {
    let (app, store, id) = try fixture("mixed-supported")
    try app.imports.accept(entries: [ShelfIngest.Entry(), entry("supported payload")], to: id)
    check(app.imports.pendingCount(for: id) == 1,
      "Mixed supported and unsupported drop reserves only the supported item")
    try await waitForShelfImports(app, "mixed supported drop")
    check(store.shelves.first { $0.id == id }?.items.map(\.value) == ["supported payload"],
      "Unsupported entry does not discard supported content in the same drop")
    check(app.imports.message(for: id)?.localizedCaseInsensitiveContains("unsupported") == true,
      "Mixed drop retains a warning about skipped unsupported content")
  }
  do {
    let (app, store, id) = try fixture("missing-advertised-file")
    let board = NSPasteboard(name: .init("shelf-missing-file-\(UUID().uuidString)"))
    defer { board.releaseGlobally() }
    let missing = root.appendingPathComponent("not-yet-provided-browser-image.png")
    let item = NSPasteboardItem()
    item.setString(missing.absoluteString, forType: .fileURL)
    item.setData(png, forType: .png)
    board.writeObjects([item])
    let captured = try ShelfIngest.entries(from: board)
    check(captured.first?.file == missing && captured.first?.imageData != nil,
      "Pasteboard capture preserves raw image fallback beside an advertised file URL")
    try app.imports.accept(entries: captured, to: id)
    try await waitForShelfImports(app, "missing file URL image fallback")
    let result = store.shelves.first { $0.id == id }?.items.first
    check(result?.kind == .image && result?.owned == true
      && result?.resolvedURL().flatMap { try? Data(contentsOf: $0) } == png,
      "Missing advertised file URL falls back to valid raw PNG on the first drop")
    check(!fm.fileExists(atPath: missing.path), "Fallback leaves the source application's advertised path untouched")
  }
  do {
    let (_, store, id) = try fixture("shared-folder-cleanup")
    let folder = try store.beginStaging()
    let retained = folder.appendingPathComponent("retained.png"), unused = folder.appendingPathComponent("unused.png")
    try png.write(to: retained); try Data("unused delivery".utf8).write(to: unused)
    try store.add([try .file(retained, owned: true, image: true)], to: id)
    store.cleanAttachments()
    check(fm.fileExists(atPath: retained.path) && fm.fileExists(atPath: unused.path),
      "Active promise lease protects every sibling while files are still arriving")
    store.finishStaging(folder)
    store.cleanAttachments()
    check(fm.fileExists(atPath: retained.path) && !fm.fileExists(atPath: unused.path),
      "Released shared promise folder keeps referenced image and prunes unused siblings")
    check(try Data(contentsOf: retained) == png, "Sibling cleanup preserves the retained image bytes")
  }
  do {
    let (app, store, id) = try fixture("mixed-promised-images")
    var promised = ShelfIngest.Entry()
    promised.promise = ShelfImportMixedPromise(image: png)
    try app.imports.accept(entries: [promised], to: id)
    try await waitForShelfImports(app, "valid and corrupt promised images")
    let result = store.shelves.first { $0.id == id }?.items
    check(result?.count == 1 && result?.first?.label == "valid.png"
      && result?.first?.resolvedURL().flatMap { try? Data(contentsOf: $0) } == png,
      "Corrupt image from one promise receiver does not discard its valid sibling")
    check(app.imports.message(for: id)?.contains("corrupt.png") == true,
      "Partial promise validation reports the rejected filename")
    let folder = result!.first!.resolvedURL()!.deletingLastPathComponent()
    check(try fm.contentsOfDirectory(atPath: folder.path) == ["valid.png"],
      "Rejected promised image is cleaned from the shared folder after completion")
    check(store.pendingDirectories.isEmpty, "Mixed promise completion releases its shared staging lease")
  }
  do {
    let (app, store, id) = try fixture("raw-priority")
    var image = ShelfIngest.Entry()
    image.imageData = (png, "png")
    image.imageURL = URL(string: "data:image/png;base64,bm90IGFuIGltYWdl")!
    image.text = "https://example.com/image-page"
    try app.imports.accept(entries: [image], to: id)
    try await waitForShelfImports(app, "raw image before URL fallback")
    let imported = store.shelves.first { $0.id == id }?.items.first
    check(imported?.kind == .image && imported?.owned == true
      && imported?.resolvedURL().flatMap { try? Data(contentsOf: $0) } == png,
      "Validated raw pixels take priority over downloading an image URL")
    check(app.imports.message(for: id) == nil, "Raw image success leaves no fallback warning")
    check(store.pendingDirectories.isEmpty, "Successful image commit releases its staging lease")
  }
  do {
    let (app, store, id) = try fixture("fallback-feedback")
    var image = ShelfIngest.Entry()
    image.imageData = (Data("HTML error page".utf8), "jpg")
    image.text = "https://example.com/retained-link"
    try app.imports.accept(entries: [image, entry("ordinary successful text")], to: id)
    try await waitForShelfImports(app, "explicit image fallback")
    check(store.shelves.first { $0.id == id }?.items.map(\.kind) == [.link, .text],
      "Unusable image data keeps the supplied link alongside successful text")
    check(app.imports.message(for: id)?.localizedCaseInsensitiveContains("link") == true,
      "Image-to-link fallback remains visible after the batch succeeds")
    check(try fm.contentsOfDirectory(atPath: store.attachments.path).isEmpty,
      "Rejected image data leaves no generated attachment behind")
  }
  do {
    let (app, store, id) = try fixture("generated-rollback")
    let savedState = try Data(contentsOf: store.stateURL)
    try fm.removeItem(at: store.stateURL)
    try fm.createDirectory(at: store.stateURL, withIntermediateDirectories: false)
    var image = ShelfIngest.Entry(); image.imageData = (png, "png")
    try app.imports.accept(entries: [image], to: id)
    try await waitForShelfImports(app, "generated image persistence failure")
    check(store.shelves.first { $0.id == id }?.items.isEmpty == true && store.pendingDirectories.isEmpty,
      "Failed image commit rolls back the shelf and releases its staging lease")
    check(try fm.contentsOfDirectory(atPath: store.attachments.path).isEmpty,
      "Failed image commit removes unreferenced staged bytes")
    try fm.removeItem(at: store.stateURL); try savedState.write(to: store.stateURL)
  }
  do {
    let (app, store, id) = try fixture("generated-quota")
    let quota = store.attachments.appendingPathComponent(UUID().uuidString).appendingPathExtension("png")
    fm.createFile(atPath: quota.path, contents: nil)
    let handle = try FileHandle(forWritingTo: quota)
    try handle.truncate(atOffset: UInt64(ShelfStore.maxStoredBytes)); try handle.close()
    try store.add([try .file(quota, owned: true, image: true)], to: id)
    var image = ShelfIngest.Entry(); image.imageData = (png, "png")
    try app.imports.accept(entries: [image], to: id)
    try await waitForShelfImports(app, "image storage quota rejection")
    check(store.shelves.first { $0.id == id }?.items.count == 1
      && app.imports.message(for: id)?.contains("200 MiB") == true,
      "Image storage limit reports an error without discarding existing items")
    check(app.imports.pendingCount(for: id) == 0 && store.pendingDirectories.isEmpty,
      "Storage quota failure releases every import reservation and lease")
    try fm.removeItem(at: quota)
  }
  do {
    let (_, store, id) = try fixture("folder-reference-cleanup")
    let folder = try store.beginStaging()
    let nested = folder.appendingPathComponent("kept-folder", isDirectory: true)
    try fm.createDirectory(at: nested, withIntermediateDirectories: true)
    let source = nested.appendingPathComponent("original.txt")
    try Data("keep folder contents".utf8).write(to: source)
    try store.add([try .file(nested)], to: id)
    store.finishStaging(folder); store.cleanAttachments()
    check(try Data(contentsOf: source) == Data("keep folder contents".utf8),
      "Cleanup preserves every child of a referenced folder inside a promise batch")
    try store.update(id) { $0.items = [try .file(folder)] }
    store.cleanAttachments()
    check(fm.fileExists(atPath: source.path),
      "Referencing a generated folder protects the complete folder")
  }

}
