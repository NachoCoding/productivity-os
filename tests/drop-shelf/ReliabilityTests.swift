import AppKit
import Carbon

private final class ReliabilityPixelProbe: NSObject, NSPasteboardItemDataProvider {
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

private final class ReliabilityOutcome: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: String?
  var value: String? { lock.lock(); defer { lock.unlock() }; return stored }
  func set(_ value: String) { lock.lock(); stored = value; lock.unlock() }
}

/// Headless regressions for the reliability pass. Nothing is shown on screen, activated, or posted;
/// apps have no displays, private pasteboards stand in for the clipboard and drag pasteboard, and
/// every store lives under the QA root.
@MainActor func runShelfReliabilityTests(root: URL) async throws {
  let fm = FileManager.default
  let folder = root.appendingPathComponent("reliability")
  try fm.createDirectory(at: folder, withIntermediateDirectories: true)
  let pixel = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 3, bitsPerSample: 8,
    samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
  let png = pixel.representation(using: .png, properties: [:])!
  let tiff = pixel.tiffRepresentation!
  var boards: [NSPasteboard] = []
  defer { for board in boards { board.releaseGlobally() } }
  func privateBoard(_ name: String) -> NSPasteboard {
    let board = NSPasteboard(name: .init("drop-shelf-reliability-\(name)-\(UUID().uuidString)"))
    boards.append(board)
    return board
  }
  func headlessApp(_ name: String) throws -> (DropShelfApp, ShelfStore) {
    let store = try ShelfStore(root: folder.appendingPathComponent(name))
    let app = DropShelfApp()
    app.store = store
    app.displayProvider = { [] }
    app.generalPasteboard = privateBoard("general-\(name)")
    app.errorObserver = { print("NOTE: \(name) reported: \($0.localizedDescription)") }
    app.cleanupDelay = 0.05
    return (app, store)
  }
  func retireAll(_ app: DropShelfApp) {
    for controller in app.allControllers { controller.retire(); controller.window?.close() }
    app.controllers.removeAll(); app.replicas.removeAll()
  }

  // P0: Delete and "Remove from Shelf" act only on an explicit selection, and stay undoable.
  do {
    let (app, store) = try headlessApp("removal")
    var reported: [String] = []
    app.errorObserver = { reported.append($0.localizedDescription) }
    let id = try store.create()
    let imageURL = try store.stage(png, extension: "png", name: "Saved image")
    let image = try ShelfItem.file(imageURL, owned: true, image: true)
    let note = try ShelfItem.text("keep this note"), link = try ShelfItem.text("https://example.com/kept")
    try store.add([image, note, link], to: id)
    let controller = ShelfController(app: app, id: id)
    app.controllers[id] = controller
    controller.selected = []
    controller.removeAction()
    await app.waitForStore()
    check(controller.items.map(\.id) == [image.id, note.id, link.id], "Delete with nothing selected removes nothing")
    check(controller.summaryLabel.stringValue.contains("Select items"), "Delete with nothing selected explains that items must be selected")
    check(controller.actionMenu().items.first { $0.title == "Remove from Shelf" }?.isEnabled == false,
      "Remove from Shelf is disabled until items are explicitly selected")
    check(controller.chosen.count == 3, "Drag-out and copy still take the whole stack when nothing is selected")
    check(app.lastRemoval == nil && fm.fileExists(atPath: imageURL.path), "A refused removal starts no undo window and keeps saved files")

    controller.select(image.id, extend: false)
    controller.removeAction()
    try await waitForShelfCondition("selected removal") { !controller.items.contains { $0.id == image.id } }
    await app.waitForStore()
    check(controller.items.map(\.id) == [note.id, link.id], "Delete removes only the selected item")
    check(fm.fileExists(atPath: imageURL.path), "A removed saved image survives the attachment sweep while undo is possible")
    check(controller.summaryLabel.stringValue.contains("⌘Z"), "Removal feedback offers ⌘Z")
    check(controller.actionMenu().items.contains { $0.title == "Undo Remove" && $0.isEnabled }, "The shelf menu offers Undo Remove")
    check(controller.undoRemoval(), "⌘Z starts restoring the last removal")
    check(!controller.undoRemoval(), "A restore in progress cannot be applied twice")
    try await waitForShelfCondition("undo") { app.lastRemoval == nil && controller.items.count == 3 }
    await app.waitForStore()
    check(controller.items.map(\.id) == [image.id, note.id, link.id], "Undo puts removed items back in their original order")
    check(fm.fileExists(atPath: imageURL.path) && controller.selected == [image.id], "Undo keeps the saved image and selects what came back")
    check(try ShelfStore(root: store.root).shelves.first { $0.id == id }?.items.count == 3, "The restored shelf is saved")
    check(!controller.undoRemoval(), "Nothing is left to undo after a restore")

    app.undoWindow = 0.05
    controller.select(image.id, extend: false)
    controller.removeAction()
    try await waitForShelfCondition("undo window expiry") { app.lastRemoval == nil && controller.items.count == 2 }
    await app.waitForStore()
    check(!fm.fileExists(atPath: imageURL.path), "After the undo window an unreferenced saved image is collected")
    check(!controller.summaryLabel.stringValue.contains("⌘Z") && !controller.undoRemoval(), "An expired removal can no longer be undone")

    app.undoWindow = 60
    let firstURL = try store.stage(png, extension: "png", name: "First"), secondURL = try store.stage(png, extension: "png", name: "Second")
    let first = try ShelfItem.file(firstURL, owned: true, image: true), second = try ShelfItem.file(secondURL, owned: true, image: true)
    try await app.withStore { try $0.add([first, second], to: id) }
    controller.select(first.id, extend: false); controller.removeAction()
    try await waitForShelfCondition("first removal") { !controller.items.contains { $0.id == first.id } }
    controller.select(second.id, extend: false); controller.removeAction()
    try await waitForShelfCondition("second removal") { !controller.items.contains { $0.id == second.id } }
    await app.waitForStore()
    check(!fm.fileExists(atPath: firstURL.path) && fm.fileExists(atPath: secondURL.path),
      "A new removal closes the previous undo window; only the latest removal keeps its files")
    check(controller.undoRemoval(), "The latest removal is still undoable")
    try await waitForShelfCondition("second undo") { controller.items.contains { $0.id == second.id } && app.lastRemoval == nil }
    await app.waitForStore()
    check(!controller.items.contains { $0.id == first.id }, "Only the latest removal is restored")

    var asked: [String] = [], answer = false
    app.confirmationHandler = { message, reply in asked.append(message); reply(answer) }
    let everything = controller.items.map(\.id)
    controller.selected = Set(everything)
    controller.removeAction()
    await app.waitForStore()
    check(asked.count == 1 && controller.items.map(\.id) == everything, "Removing every item asks first; declining keeps the shelf intact")
    answer = true
    controller.removeAction()
    try await waitForShelfCondition("remove all") { controller.items.isEmpty }
    check(asked.count == 2 && controller.undoRemoval(), "Confirmed Remove All empties the shelf and stays undoable")
    try await waitForShelfCondition("undo remove all") { controller.items.map(\.id) == everything && app.lastRemoval == nil }
    await app.waitForStore()
    check(reported.isEmpty, "Removal and undo report no errors")
    retireAll(app)
  }

  // ⌥⇧Space: shown from memory first, saved afterwards in order, and an empty shelf is reused.
  do {
    let (app, store) = try headlessApp("shortcut")
    var reported: [String] = []
    app.errorObserver = { reported.append($0.localizedDescription) }
    guard let first = app.openEmptyShelf(near: .zero, activate: true) else { throw ShelfError("Shortcut fixture did not open a shelf") }
    let firstID = first.id
    check(store.shelves.first?.id == firstID && app.controllers[firstID] === first,
      "The shortcut shows a shelf from memory without waiting for history to be saved")
    check(try store.staged.count == 1 && ShelfStore(root: store.root).shelves.isEmpty, "The new shelf is saved after it is shown")
    check(app.openEmptyShelf(near: .zero, activate: true) === first && store.shelves.count == 1,
      "Pressing the shortcut again reuses the empty shelf instead of stacking another")
    first.change { $0.color = 3 }
    try await waitForShelfCondition("edit right after the shortcut") { store.shelves.first { $0.id == firstID }?.color == 3 }
    await app.waitForStore()
    check(try ShelfStore(root: store.root).shelves.first { $0.id == firstID }?.color == 3 && store.staged.isEmpty,
      "An edit made right after the shortcut is saved after the shelf itself")
    try await app.withStore { try $0.add([try .text("now in use")], to: firstID) }
    guard let second = app.openEmptyShelf(near: .zero, activate: true) else { throw ShelfError("Second shortcut fixture failed") }
    check(second.id != firstID && store.shelves.count == 2, "A shelf with items is not reused; the shortcut creates a new one")
    second.change { $0.name = "Invoices" }
    try await waitForShelfCondition("naming the second shelf") { store.shelves.first { $0.id == second.id }?.name == "Invoices" }
    await app.waitForStore()
    check(app.openEmptyShelf(near: .zero, activate: true)?.id != second.id && store.shelves.count == 3,
      "A named empty shelf keeps its purpose and is not reused")
    await app.waitForStore()

    let started = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
    let blocker = Task { @MainActor in
      try await app.withStore { snapshot in
        started.signal()
        guard release.wait(timeout: .now() + 2) == .success else { throw ShelfError("Fixture did not release the store worker") }
        try snapshot.update(firstID) { $0.name = "Written while blocked" }
      }
    }
    try await waitForShelfCondition("blocked store worker") { started.wait(timeout: .now()) == .success }
    guard let pending = app.newShelf(near: .zero, activate: false) else { release.signal(); throw ShelfError("Blocked shortcut fixture failed") }
    check(store.shelves.contains { $0.id == pending.id }, "A shelf can be shown while an earlier history write is still running")
    release.signal()
    try await blocker.value
    check(store.shelves.contains { $0.id == pending.id } && store.shelves.first { $0.id == firstID }?.name == "Written while blocked",
      "Publishing the earlier write keeps the not-yet-saved shelf visible")
    await app.waitForStore()
    check(try ShelfStore(root: store.root).shelves.contains { $0.id == pending.id } && store.staged.isEmpty,
      "The shelf shown during the earlier write is saved right after it")

    let savedState = try Data(contentsOf: store.stateURL)
    try fm.removeItem(at: store.stateURL)
    try fm.createDirectory(at: store.stateURL, withIntermediateDirectories: false)
    reported = []
    guard let failing = app.newShelf(near: .zero, activate: false) else { throw ShelfError("Failing shortcut fixture failed") }
    let failingID = failing.id
    try await waitForShelfCondition("failed shelf save") { !reported.isEmpty }
    check(!store.shelves.contains { $0.id == failingID } && app.controllers[failingID] == nil && store.staged.isEmpty,
      "A shelf whose save fails is withdrawn and the error is reported")
    try fm.removeItem(at: store.stateURL); try savedState.write(to: store.stateURL)
    retireAll(app)
    await app.waitForStore()

    let (full, fullStore) = try headlessApp("shortcut-full")
    for _ in 0..<30 { _ = try fullStore.create() }
    var fullReports: [String] = []
    full.errorObserver = { fullReports.append($0.localizedDescription) }
    check(full.newShelf(near: .zero, activate: true) == nil && fullReports.first?.contains("30 shelf limit") == true
      && full.controllers.isEmpty && fullStore.shelves.count == 30,
      "At the 30-shelf limit nothing is shown and the limit is explained")

    let (timed, timedStore) = try headlessApp("shortcut-timing")
    var times: [Double] = []
    for _ in 0..<20 {
      let start = ProcessInfo.processInfo.systemUptime
      guard let shown = timed.newShelf(near: .zero, activate: true) else { throw ShelfError("Timing fixture failed") }
      times.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
      shown.closeShelf()
      try await waitForShelfCondition("timing fixture close") { timedStore.shelves.first { $0.id == shown.id }?.closed == true }
      await timed.waitForStore()
    }
    let p95 = times.sorted()[18]
    print("UI_PERFORMANCE shortcut_new_shelf_p95_ms=\(p95) (offscreen panel and chrome, no history wait)")
    check(p95 < 50, "Creating the shortcut's shelf stays below 50 ms at p95 without waiting for disk")
    retireAll(timed)
  }

  // Launcher protocol: pos-shelf://quit-if-idle quits only an idle helper and never shows UI.
  do {
    let (app, store) = try headlessApp("quit")
    var quits = 0
    app.terminator = { quits += 1 }
    app.application(NSApp, open: [URL(string: "pos-shelf://quit-if-idle")!])
    try await waitForShelfCondition("idle quit") { quits == 1 }
    check(app.allControllers.isEmpty && app.settings == nil && store.shelves.isEmpty,
      "quit-if-idle quits an idle helper without creating a shelf or showing a window")
    guard let shown = app.openEmptyShelf(near: .zero, activate: false) else { throw ShelfError("Quit fixture shelf failed") }
    app.quitIfIdle()
    try await Task.sleep(nanoseconds: 50_000_000); await app.waitForStore()
    check(quits == 1, "quit-if-idle keeps Drop Shelf running while a shelf is open")
    shown.closeShelf()
    try await waitForShelfCondition("closing the open shelf") {
      store.shelves.first { $0.id == shown.id }?.closed == true && app.allControllers.isEmpty
    }
    let gate = ShelfImportGate()
    app.imports.resolver = { try await gate.resolve($0) }
    try app.imports.accept(entries: [ShelfIngest.Entry(text: "held import")], to: shown.id)
    app.quitIfIdle()
    try await Task.sleep(nanoseconds: 50_000_000)
    check(quits == 1, "quit-if-idle waits while an import is in flight")
    try await waitForShelfCondition("held import resolver") { gate.keys.contains("held import") }
    gate.finish("held import", items: [try .text("held import")])
    try await waitForShelfImports(app, "held import before quitting")
    app.imports.resolver = nil
    app.busy = true
    app.quitIfIdle(); try await Task.sleep(nanoseconds: 50_000_000)
    check(quits == 1, "quit-if-idle waits while a copy or ZIP is running")
    app.busy = false
    let lease = UUID()
    app.activeDragURLs[lease] = []
    app.quitIfIdle(); try await Task.sleep(nanoseconds: 50_000_000)
    check(quits == 1, "quit-if-idle waits while a drag is in progress")
    app.activeDragURLs.removeValue(forKey: lease)
    app.application(NSApp, open: [URL(string: "pos-shelf://quit-if-idle")!])
    try await waitForShelfCondition("quit once idle again") { quits == 2 }
    check(quits == 2, "quit-if-idle quits once the work has finished")
  }

  // Start at login writes the shared LaunchAgent contract atomically; turning it off only deletes it.
  do {
    let (app, _) = try headlessApp("login")
    app.loginURL = folder.appendingPathComponent("LaunchAgents/com.productivity-os.drop-shelf.plist")
    try app.setStartAtLogin(true)
    let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: app.loginURL), format: nil) as? [String: Any] ?? [:]
    check(Set(plist.keys) == ["Label", "ProgramArguments", "RunAtLoad", "KeepAlive", "ProcessType", "ThrottleInterval", "LimitLoadToSessionType"],
      "Start at login writes exactly the shared LaunchAgent keys")
    check(plist["Label"] as? String == "com.productivity-os.drop-shelf"
      && (plist["ProgramArguments"] as? [String]) == [Bundle.main.executablePath ?? "", "--background"]
      && plist["RunAtLoad"] as? Bool == true && (plist["KeepAlive"] as? [String: Bool]) == ["SuccessfulExit": false]
      && plist["ProcessType"] as? String == "Interactive" && plist["ThrottleInterval"] as? Int == 30
      && plist["LimitLoadToSessionType"] as? String == "Aqua",
      "The LaunchAgent restarts crashes only, as an interactive Aqua agent throttled to 30 seconds")
    check(try fm.contentsOfDirectory(atPath: app.loginURL.deletingLastPathComponent().path) == [app.loginURL.lastPathComponent],
      "The agent is written atomically with no temporary files left behind")
    try app.setStartAtLogin(false)
    check(!fm.fileExists(atPath: app.loginURL.path), "Turning start at login off deletes only the agent file")
    try app.setStartAtLogin(false)
    check(!fm.fileExists(atPath: app.loginURL.path), "Turning it off again is harmless")
  }

  // A damaged shelves.json is moved aside with its saved images, and the app starts fresh.
  do {
    let damagedRoot = folder.appendingPathComponent("damaged-history")
    let items = damagedRoot.appendingPathComponent("Items", isDirectory: true)
    try fm.createDirectory(at: items, withIntermediateDirectories: true)
    let savedImage = items.appendingPathComponent(UUID().uuidString).appendingPathExtension("png")
    try png.write(to: savedImage)
    let broken = Data(#"[{"id": "not a shelf""#.utf8)
    try broken.write(to: damagedRoot.appendingPathComponent("shelves.json"))
    let opened = try ShelfStore.open(root: damagedRoot, now: Date(timeIntervalSince1970: 1_700_000_000))
    let keptHistory = damagedRoot.appendingPathComponent("shelves.json.damaged-1700000000")
    let keptImage = damagedRoot.appendingPathComponent("Items.damaged-1700000000").appendingPathComponent(savedImage.lastPathComponent)
    check(opened.store.shelves.isEmpty && opened.recovery != nil, "Damaged history opens as an empty history instead of stopping the app")
    check(try Data(contentsOf: keptHistory) == broken, "The damaged history file is kept byte for byte")
    check(try Data(contentsOf: keptImage) == png && !fm.fileExists(atPath: savedImage.path),
      "Saved images of the damaged history are moved aside so no cleanup can delete them")
    check(opened.recovery?.notice.contains(keptHistory.lastPathComponent) == true && opened.recovery?.keptFiles.first == keptHistory,
      "The visible notice names the kept file")
    _ = try opened.store.create(); opened.store.cleanAttachments()
    check(try fm.fileExists(atPath: keptImage.path) && ShelfStore(root: damagedRoot).shelves.count == 1,
      "The fresh history saves normally and its cleanup leaves the kept images alone")
    let healthy = try ShelfStore.open(root: damagedRoot)
    check(healthy.recovery == nil && healthy.store.shelves.count == 1, "A healthy history opens without recovery")
  }

  // ZIP and copy: bounded by a timeout, cancellable, and never able to block logout.
  do {
    let sleep = URL(fileURLWithPath: "/bin/sleep")
    let start = ProcessInfo.processInfo.systemUptime
    do { try ShelfFiles.run(sleep, ["30"], timeout: 0.2); check(false, "A stuck ZIP process is stopped at its timeout") }
    catch {
      check(error.localizedDescription.contains("stopped") && ProcessInfo.processInfo.systemUptime - start < 5,
        "A stuck ZIP process is stopped at its timeout")
    }
    let job = ShelfExportJob(), outcome = ReliabilityOutcome(), finished = DispatchSemaphore(value: 0)
    DispatchQueue.global(qos: .utility).async {
      do { try ShelfFiles.run(sleep, ["30"], timeout: 30, job: job); outcome.set("finished") }
      catch { outcome.set(error.localizedDescription) }
      finished.signal()
    }
    try await Task.sleep(nanoseconds: 150_000_000)
    let cancelStart = ProcessInfo.processInfo.systemUptime
    job.cancel()
    try await waitForShelfCondition("cancelled export process") { finished.wait(timeout: .now()) == .success }
    check(outcome.value?.contains("cancelled") == true && ProcessInfo.processInfo.systemUptime - cancelStart < 5,
      "Cancelling an export stops its running process promptly")
    let cancelled = ShelfExportJob(); cancelled.cancel()
    let zipOut = folder.appendingPathComponent("cancelled-zip")
    try fm.createDirectory(at: zipOut, withIntermediateDirectories: true)
    rejects("A cancelled export copies nothing") { _ = try ShelfFiles.archive([try .text("not copied")], to: zipOut, job: cancelled) }
    check(try fm.contentsOfDirectory(atPath: zipOut.path).isEmpty, "A cancelled ZIP leaves the destination untouched")

    let (app, _) = try headlessApp("logout")
    let exporting = ShelfExportJob()
    app.busy = true; app.exportJob = exporting
    check(app.applicationShouldTerminate(NSApp) == .terminateCancel && !exporting.isCancelled,
      "An ordinary quit request still waits for a running export")
    app.sessionEnding = true
    check(app.applicationShouldTerminate(NSApp) == .terminateNow && exporting.isCancelled,
      "Logout, restart, or shutdown cancels the export instead of being blocked by it")
    app.sessionEnding = false; app.busy = false; app.exportJob = nil
    func quitEvent(_ reason: OSType?) -> NSAppleEventDescriptor {
      let event = NSAppleEventDescriptor(eventClass: AEEventClass(kCoreEventClass), eventID: AEEventID(kAEQuitApplication),
        targetDescriptor: nil, returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
      if let reason { event.setAttribute(NSAppleEventDescriptor(typeCode: reason), forKeyword: AEKeyword(kAEQuitReason)) }
      return event
    }
    check(DropShelfApp.isSessionEnd(quitEvent(kAELogOut)) && DropShelfApp.isSessionEnd(quitEvent(kAEShutDown))
      && DropShelfApp.isSessionEnd(quitEvent(kAEShowRestartDialog)) && !DropShelfApp.isSessionEnd(quitEvent(nil)),
      "Quit requests sent for logout, restart, or shutdown are told apart from an ordinary quit")
  }

  // Shake to open: motion first, one drag-pasteboard check per drag, no monitor while disabled.
  do {
    let (app, _) = try headlessApp("shake")
    let suite = "drop-shelf-shake-\(UUID().uuidString)"
    app.defaults = UserDefaults(suiteName: suite)!
    defer { app.defaults.removePersistentDomain(forName: suite) }
    let dragBoard = privateBoard("drag")
    app.dragPasteboard = dragBoard
    var pointer = NSPoint.zero
    app.pointerLocation = { pointer }
    func drag(_ x: CGFloat, at time: TimeInterval) {
      pointer = NSPoint(x: x, y: 0)
      app.observeDrag(NSEvent.mouseEvent(with: .leftMouseDragged, location: pointer, modifierFlags: [], timestamp: time,
        windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!)
    }
    func shakeGesture(at time: TimeInterval) {
      for (index, x) in [0, 45, 0, 45, 0].enumerated() { drag(CGFloat(x), at: time + Double(index) * 0.04) }
    }
    app.applyShakeSetting()
    check(app.shakeEnabled && app.dragMonitorInstalled, "Shake to open watches drags while it is enabled")
    dragBoard.clearContents(); dragBoard.writeObjects([folder as NSURL])
    for index in 0..<40 { drag(CGFloat(index) * 20, at: Double(index) * 0.016) }
    check(app.dragPasteboardReads == 0 && app.allControllers.isEmpty, "Ordinary drag motion never reads the drag pasteboard")
    shakeGesture(at: 10)
    check(app.dragPasteboardReads == 1 && app.allControllers.count == 1, "A shake during a file drag opens a shelf after one pasteboard check")
    shakeGesture(at: 20)
    check(app.dragPasteboardReads == 1, "Further shakes during the same drag reuse that check")
    dragBoard.clearContents(); dragBoard.setString("private", forType: .init("org.productivity-os.test.private"))
    let shelves = app.allControllers.count
    shakeGesture(at: 30)
    check(app.dragPasteboardReads == 2 && app.allControllers.count == shelves,
      "A shake while dragging something that is not shelf content opens nothing")
    let toggle = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    toggle.state = .off; app.toggleShake(toggle)
    check(!app.shakeEnabled && !app.dragMonitorInstalled && app.defaults.object(forKey: "shake") as? Bool == false,
      "Turning shake off saves the choice and removes the drag monitor")
    dragBoard.clearContents(); dragBoard.writeObjects([folder as NSURL])
    shakeGesture(at: 40)
    check(app.dragPasteboardReads == 2 && app.allControllers.count == shelves, "With shake off, drags do no work at all")
    toggle.state = .on; app.toggleShake(toggle)
    check(app.shakeEnabled && app.dragMonitorInstalled, "Turning shake back on restores the monitor")
    toggle.state = .off; app.toggleShake(toggle)
    retireAll(app)
    await app.waitForStore()
  }

  // Attachment cleanup: debounced to one sweep, and the clipboard is read only when it matters.
  do {
    let (app, store) = try headlessApp("cleanup")
    app.cleanupDelay = 0.2
    let orphan = try store.stage(png, extension: "png")
    let sweepsBefore = app.cleanupSweeps
    for _ in 0..<25 { app.cleanAttachments() }
    check(app.storeOperations == 0 && app.cleanupSweeps == sweepsBefore && fm.fileExists(atPath: orphan.path),
      "A burst of cleanup requests is deferred instead of queuing a sweep for each")
    try await waitForShelfCondition("debounced sweep") { !fm.fileExists(atPath: orphan.path) }
    await app.waitForStore()
    check(app.cleanupSweeps == sweepsBefore + 1, "Twenty-five cleanup requests run a single sweep")
    let general = app.generalPasteboard
    general.clearContents(); general.setString("plain text", forType: .string)
    let readsBefore = app.clipboardContentReads
    _ = app.protectedAttachmentURLs(); _ = app.protectedAttachmentURLs()
    check(app.clipboardContentReads == readsBefore, "Clipboard text is never read for cleanup")
    let copied = try store.stage(png, extension: "png")
    general.clearContents(); general.writeObjects([copied as NSURL])
    let protected = app.protectedAttachmentURLs(); _ = app.protectedAttachmentURLs()
    check(app.clipboardContentReads == readsBefore + 1 && protected.contains { $0.standardizedFileURL.path == copied.standardizedFileURL.path },
      "Clipboard file references are read once per clipboard change")
    app.cleanAttachments(); await app.waitForStore()
    check(fm.fileExists(atPath: copied.path), "A saved image on the clipboard is protected from cleanup")
    let id = try store.create()
    let ownedURL = try store.stage(png, extension: "png", name: "Copied from shelf")
    try await app.withStore { try $0.add([try ShelfItem.file(ownedURL, owned: true, image: true)], to: id) }
    let controller = ShelfController(app: app, id: id)
    app.controllers[id] = controller
    let readsBeforeCopy = app.clipboardContentReads
    controller.copyItems(to: general)
    let afterCopy = app.protectedAttachmentURLs()
    check(app.clipboardContentReads == readsBeforeCopy && afterCopy.contains { $0.standardizedFileURL.path == ownedURL.standardizedFileURL.path },
      "Copying from a shelf protects the copied files without reading the clipboard back")
    retireAll(app)
    await app.waitForStore()
  }

  // Ingest: TIFF is transferred only when no file, promise, URL, or compact encoding can supply the image.
  do {
    let board = privateBoard("tiff")
    func capture(_ configure: (NSPasteboardItem) -> Void, tiffProbe: ReliabilityPixelProbe, png pngProbe: ReliabilityPixelProbe? = nil) throws -> ShelfIngest.Entry {
      let item = NSPasteboardItem(); configure(item)
      item.setDataProvider(tiffProbe, forTypes: [.tiff])
      if let pngProbe { item.setDataProvider(pngProbe, forTypes: [.png]) }
      board.clearContents(); board.writeObjects([item])
      return try ShelfIngest.entries(from: board)[0]
    }
    let urlTIFF = ReliabilityPixelProbe(tiff)
    let withURL = try capture({ $0.setString("https://example.com/original.jpg", forType: .URL) }, tiffProbe: urlTIFF)
    check(urlTIFF.reads == 0 && withURL.imageData == nil && withURL.imageURL != nil,
      "TIFF pixels are not transferred when the original image URL is available")
    let compactTIFF = ReliabilityPixelProbe(tiff), compactPNG = ReliabilityPixelProbe(png)
    let withPNG = try capture({ _ in }, tiffProbe: compactTIFF, png: compactPNG)
    check(compactTIFF.reads == 0 && compactPNG.reads == 1 && withPNG.imageData?.0 == png, "A compact encoding is used instead of the TIFF copy")
    let fileTIFF = ReliabilityPixelProbe(tiff)
    let existing = folder.appendingPathComponent("existing-original.png")
    try png.write(to: existing)
    let withFile = try capture({ $0.setString(existing.absoluteString, forType: .fileURL) }, tiffProbe: fileTIFF)
    check(fileTIFF.reads == 0 && withFile.file != nil && withFile.imageData == nil, "An existing file is preferred over its TIFF pixels")
    let onlyTIFF = ReliabilityPixelProbe(tiff)
    let tiffOnly = try capture({ _ in }, tiffProbe: onlyTIFF)
    check(onlyTIFF.reads == 1 && tiffOnly.imageData?.0 == tiff, "TIFF is still read when it is the only image source")
  }

  // Thumbnails: one shared cache per shelf, and work only when the visible items change.
  do {
    var loads: [ShelfThumbnailCache.Key: @MainActor (NSImage?) -> Void] = [:]
    var cancels = Set<ShelfThumbnailCache.Key>()
    let shared = ShelfThumbnailCache(capacity: 8) { key, completion in
      loads[key] = completion
      return { cancels.insert(key) }
    }
    let key = ShelfThumbnailCache.Key(id: UUID(), url: folder.appendingPathComponent("shared-thumb.png"), scale: 2)
    let left = NSObject(), right = NSObject()
    var leftImages = 0, rightImages = 0
    shared.update([key], for: left) { _, _ in leftImages += 1 }
    shared.update([key], for: right) { _, _ in rightImages += 1 }
    check(loads.count == 1 && shared.activeCount == 1, "Two display copies showing the same item share one thumbnail request")
    shared.update([], for: left) { _, _ in }
    check(cancels.isEmpty && shared.activeCount == 1, "One copy scrolling away does not cancel a thumbnail the other copy still shows")
    loads[key]?(NSImage(size: NSSize(width: 4, height: 4)))
    check(rightImages == 1 && leftImages == 0 && shared.cacheCount == 1, "The finished thumbnail goes to the copy that still shows it")
    shared.update([key], for: left) { _, _ in leftImages += 1 }
    check(leftImages == 1 && loads.count == 1, "The other copy reuses the cached thumbnail without another request")
    shared.remove(right); shared.remove(left)
    check(shared.activeCount == 0, "Retired copies release their thumbnail requests")

    let (app, store) = try headlessApp("thumbnails")
    let big = NSRect(x: 0, y: 0, width: 1600, height: 1000), display = ShelfDisplay(id: 9, frame: big, visibleFrame: big)
    let id = try store.create()
    try store.add(try (0..<60).map { try ShelfItem.text("Thumbnail row \($0)") }, to: id)
    let controller = ShelfController(app: app, id: id, display: display)
    app.controllers[id] = controller
    let copy = ShelfController(app: app, id: id, presentation: controller.presentation, display: display)
    check(copy.presentation.thumbnails === controller.presentation.thumbnails, "Display copies of one shelf share a single thumbnail cache")
    copy.retire(); copy.window?.close()
    controller.expanded = true; controller.render()
    let passes = controller.thumbnailPasses
    controller.message = "Status only"; controller.render()
    controller.select(controller.items[0].id, extend: false)
    controller.scrollView.contentView.scroll(to: NSPoint(x: 0, y: 10))
    controller.scrollView.reflectScrolledClipView(controller.scrollView.contentView)
    check(controller.thumbnailPasses == passes, "Status, selection, and scrolling within the same rows do no thumbnail work")
    controller.scrollView.contentView.scroll(to: NSPoint(x: 0, y: 468))
    controller.scrollView.reflectScrolledClipView(controller.scrollView.contentView)
    check(controller.thumbnailPasses == passes + 1, "Scrolling to new rows updates thumbnails once")

    let fileURL = folder.appendingPathComponent("bookmarked-thumbnail.png")
    try png.write(to: fileURL)
    let referenced = try ShelfItem.file(fileURL)
    let referencedID = try store.create()
    try store.add([referenced], to: referencedID)
    let referencing = ShelfController(app: app, id: referencedID, display: display)
    app.controllers[referencedID] = referencing
    check(referenced.bookmark != nil && referencing.presentation.resolvedURLs[referenced.id] == nil
      && referencing.presentation.resolving.contains(referenced.id),
      "Rendering does not resolve file bookmarks on the main thread")
    try await waitForShelfCondition("background bookmark resolution") { referencing.presentation.resolvedURLs[referenced.id] != nil }
    check(referencing.presentation.resolvedURLs[referenced.id]?.resolvingSymlinksInPath() == fileURL.resolvingSymlinksInPath(),
      "Bookmarks resolve in the background and the shelf picks up the result")
    retireAll(app)
    await app.waitForStore()
  }
  print("Drop Shelf reliability checks complete")
}
