import AppKit
import Carbon

@MainActor final class ShelfStatusDrop: NSView {
  weak var app: DropShelfApp?
  override init(frame: NSRect) {
    super.init(frame: frame)
    registerForDraggedTypes(ShelfIngest.dragTypes)
    setAccessibilityElement(true); setAccessibilityRole(.button); setAccessibilityLabel("Drop Shelf")
  }
  required init?(coder: NSCoder) { fatalError() }
  override func mouseDown(with event: NSEvent) {
    guard let app else { return }
    app.updateMenu(); app.menu.popUp(positioning: nil, at: NSPoint(x: 0, y: 0), in: self)
  }
  override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }
  override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { true }
  override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
    guard let app else { return false }
    do {
      let entries = try ShelfIngest.entries(from: sender.draggingPasteboard, preferFileReferences: sender.draggingSource is ShelfTile)
      // The shelf exists in memory at once, so the drop is accepted (and its files protected) synchronously.
      guard !entries.isEmpty, let shelf = app.newShelf() else { return false }
      do { try app.imports.accept(entries: entries, to: shelf.id) }
      catch { app.refreshShelf(shelf.id, message: error.localizedDescription) }
      return true
    } catch { return false }
  }
}
/// The last removal stays undoable for a short window; until then its saved files are not swept.
@MainActor final class ShelfRemoval {
  let shelfID: UUID
  let entries: [(offset: Int, item: ShelfItem)]
  let hint: String
  var restoring = false
  fileprivate var expiry: DispatchWorkItem?
  init(shelfID: UUID, entries: [(offset: Int, item: ShelfItem)]) {
    self.shelfID = shelfID; self.entries = entries
    hint = "Removed \(entries.count) item\(entries.count == 1 ? "" : "s") · ⌘Z to undo"
  }
  var protectedURLs: [URL] { entries.compactMap { $0.item.url } }
}
@MainActor final class DropShelfApp: NSObject, NSApplicationDelegate, NSWindowDelegate {
  static let shared = DropShelfApp()
  static let bundleID = "com.productivity-os.drop-shelf"
  static let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Productivity OS/Drop Shelf")
  var store: ShelfStore?
  lazy var imports = ShelfImportCoordinator(app: self)
  private var storeTask: Task<Void, Never>?
  private(set) var storeOperations = 0
  /// Queues a transaction immediately, so its order is fixed even when the caller does not await it.
  /// Snapshots are taken and published on the main actor; transactions and file IO run on one worker.
  @discardableResult func enqueueStore<T: Sendable>(priority: TaskPriority = .userInitiated, _ operation: @escaping (ShelfStore) throws -> T) -> Task<T, Error> {
    let previous = storeTask
    storeOperations += 1
    let task = Task { @MainActor in
      defer { self.storeOperations -= 1 }
      await previous?.value
      guard let store = self.store else { throw ShelfError("Shelf history is unavailable.") }
      let snapshot = store.snapshot()
      let result = try await Task.detached(priority: priority) {
        let value = try operation(snapshot)
        return (value, snapshot)
      }.value
      store.publish(result.1)
      return result.0
    }
    storeTask = Task { _ = try? await task.value }
    return task
  }
  func withStore<T: Sendable>(priority: TaskPriority = .userInitiated, _ operation: @escaping (ShelfStore) throws -> T) async throws -> T {
    try await enqueueStore(priority: priority, operation).value
  }
  /// Waits for queued history work, including a scheduled attachment sweep.
  func waitForStore() async {
    await flushAttachmentCleanup()
    await storeTask?.value
  }
  var activeDragURLs: [UUID: [URL]] = [:]
  var hasActiveWork: Bool { busy || imports.isBusy || storeOperations > 0 || !activeDragURLs.isEmpty }
  var controllers: [UUID: ShelfController] = [:]
  /// The primary remains compatible with callers that hold one controller per logical shelf.
  /// Additional panels share its presentation and store-backed items, keyed by physical display.
  var replicas: [UUID: [UInt32: ShelfController]] = [:]
  var displayProvider: () -> [ShelfDisplay] = { ShelfDisplay.current }
  private var displayObserver: NSObjectProtocol?
  private var defaultsObserver: NSObjectProtocol?
  private var powerOffObserver: NSObjectProtocol?
  private var lastDisplays: [UInt32: ShelfDisplay] = [:]
  private var lastPrimaries: [UUID: ObjectIdentifier] = [:]
  private var reconcilingDisplays = false
  private(set) var displaySyncDeferred = false
  func shelfControllers(_ id: UUID) -> [ShelfController] {
    var result: [ShelfController] = []
    if let primary = controllers[id] { result.append(primary) }
    var seen = Set(result.map(ObjectIdentifier.init))
    for key in (replicas[id]?.keys.sorted() ?? []) {
      if let copy = replicas[id]?[key], seen.insert(ObjectIdentifier(copy)).inserted { result.append(copy) }
    }
    return result
  }
  var allControllers: [ShelfController] {
    Set(controllers.keys).union(replicas.keys).sorted { $0.uuidString < $1.uuidString }.flatMap(shelfControllers)
  }
  func renderShelf(_ id: UUID) { for controller in shelfControllers(id) { controller.render() } }
  func refreshShelf(_ id: UUID, message: String?) {
    let copies = shelfControllers(id)
    for controller in copies { controller.message = message }
    for controller in copies { controller.render() }
  }
  private var hasProtectedInteraction: Bool {
    allControllers.contains { $0.activeGesture || $0.window?.attachedSheet != nil }
  }
  private func currentDisplays() -> [ShelfDisplay] {
    var seen = Set<UInt32>()
    return displayProvider().filter { $0.frame.width > 0 && $0.frame.height > 0 && seen.insert($0.id).inserted }
  }
  private func preferredDisplay(in displays: [ShelfDisplay], near point: NSPoint? = nil, frame: NSRect? = nil) -> ShelfDisplay? {
    guard let index = ShelfPlacement.screenIndex(frames: displays.map(\.frame), near: point, preserving: frame) else { return nil }
    return displays[index]
  }
  private func removeClosedControllers() {
    guard !hasProtectedInteraction else { displaySyncDeferred = true; return }
    for id in Set(controllers.keys).union(replicas.keys) where store?.shelves.first(where: { $0.id == id })?.closed != false {
      for controller in shelfControllers(id) { controller.retire() }
      controllers.removeValue(forKey: id); replicas.removeValue(forKey: id)
    }
  }
  /// Reconcile physical display changes without replacing surviving panels or reviving history.
  /// The common mouse-up path is a descriptor/identity comparison, with no rendering or ordering.
  func synchronizeDisplays() {
    guard !reconcilingDisplays else { return }
    guard !hasProtectedInteraction else { displaySyncDeferred = true; return }
    reconcilingDisplays = true
    defer { reconcilingDisplays = false }
    displaySyncDeferred = false
    removeClosedControllers()
    let displays = currentDisplays()
    let desired = Dictionary(uniqueKeysWithValues: displays.map { ($0.id, $0) })
    let identities = controllers.mapValues(ObjectIdentifier.init)
    guard desired != lastDisplays || identities != lastPrimaries else { return }
    guard !displays.isEmpty else {
      for controller in allControllers { controller.window?.orderOut(nil) }
      lastDisplays = desired; lastPrimaries = identities
      return
    }
    for id in Array(controllers.keys) {
      guard var primary = controllers[id], store?.shelves.first(where: { $0.id == id })?.closed == false else { continue }
      let previous = shelfControllers(id)
      if primary.display == nil { primary.display = preferredDisplay(in: displays, frame: primary.window?.frame) }
      var copies: [UInt32: ShelfController] = [:]
      for controller in previous {
        if let display = controller.display, desired[display.id] != nil, copies[display.id] == nil { copies[display.id] = controller }
      }
      if primary.display.flatMap({ copies[$0.id] }) !== primary {
        if let survivingID = copies.keys.sorted().first, let surviving = copies[survivingID] { primary = surviving }
        else if let destination = preferredDisplay(in: displays, frame: primary.window?.frame) {
          primary.display = destination; copies[destination.id] = primary
        }
      }
      for display in displays {
        if let copy = copies[display.id] { copy.display = display }
        else { copies[display.id] = ShelfController(app: self, id: id, presentation: primary.presentation, display: display) }
      }
      let retained = Set(copies.values.map(ObjectIdentifier.init))
      for controller in previous where !retained.contains(ObjectIdentifier(controller)) { controller.retire() }
      controllers[id] = primary
      replicas[id] = copies.filter { $0.value !== primary }
      for controller in shelfControllers(id) { controller.present(activate: false) }
    }
    lastDisplays = desired; lastPrimaries = controllers.mapValues(ObjectIdentifier.init)
  }
  var statusItem: NSStatusItem?, menu = NSMenu()
  var keyMonitor: Any?
  var hotkey: EventHotKeyRef?, handler: EventHandlerRef?
  var shake = ShelfShakeDetector()
  var busy = false
  var exportURLs: [URL] = []
  var exportJob: ShelfExportJob?
  var exportTimeout = ShelfFiles.zipTimeout
  private var quitAfterExport = false
  var settings: NSWindow?, shortcutButton: NSButton?
  var recording = false
  var shortcutProblem: String?
  var receivedCommand = false
  var defaults = UserDefaults.standard
  private(set) var storeRecovery: ShelfStoreRecovery?
  var loginURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/\(DropShelfApp.bundleID).plist")
  /// Test seams: production alerts, quits, and asks with AppKit.
  var errorObserver: ((Error) -> Void)?
  var confirmationHandler: ((String, @escaping (Bool) -> Void) -> Void)?
  var terminator: @MainActor () -> Void = { NSApp.terminate(nil) }
  deinit { if let displayObserver { NotificationCenter.default.removeObserver(displayObserver) } }
  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.accessory)
    if NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).contains(where: { $0.processIdentifier != getpid() }) { NSApp.terminate(nil); return }
    do {
      let opened = try ShelfStore.open(root: Self.root)
      store = opened.store; storeRecovery = opened.recovery
    } catch { report(error); NSApp.terminate(nil); return }
    cleanAttachments()
    let main = NSMenu(), edit = NSMenuItem(title: "Edit", action: nil, keyEquivalent: ""), submenu = NSMenu(title: "Edit")
    for (title, selector, key) in [("Cut", #selector(NSText.cut(_:)), "x"), ("Copy", #selector(NSText.copy(_:)), "c"), ("Paste", #selector(NSText.paste(_:)), "v"), ("Select All", #selector(NSText.selectAll(_:)), "a")] {
      submenu.addItem(withTitle: title, action: selector, keyEquivalent: key)
    }
    edit.submenu = submenu; main.addItem(edit); NSApp.mainMenu = main
    statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    if let button = statusItem?.button {
      button.image = NSImage(systemSymbolName: "tray", accessibilityDescription: "Drop Shelf")
      let drop = ShelfStatusDrop(frame: button.bounds); drop.autoresizingMask = [.width, .height]; drop.app = self; button.addSubview(drop)
    }
    updateMenu(); registerShortcut()
    displayObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated { self?.synchronizeDisplays() }
    }
    defaultsObserver = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated { self?.applyShakeSetting() }
    }
    powerOffObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willPowerOffNotification, object: nil, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated { self?.noteSessionEnding() }
    }
    applyShakeSetting()
    keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
      let consumed = MainActor.assumeIsolated { self?.handleKey(event) == nil }
      return consumed ? nil : event
    }
    if let notice = storeRecovery?.notice { DispatchQueue.main.async { [weak self] in self?.report(ShelfError(notice)) } }
    if !receivedCommand && !CommandLine.arguments.contains("--background") { openEmptyShelf() }
  }
  func application(_ application: NSApplication, open urls: [URL]) {
    receivedCommand = true
    // LaunchServices may deliver URLs before applicationDidFinishLaunching.
    Task { @MainActor [weak self] in
      guard let self else { return }
      let files = urls.filter(\.isFileURL)
      if !files.isEmpty, let shelf = self.newShelf() {
        do { try self.imports.accept(entries: files.map { ShelfIngest.Entry(file: $0) }, to: shelf.id) }
        catch { self.report(error) }
      }
      for url in urls where !url.isFileURL {
        guard url.scheme == "pos-shelf", url.query == nil, url.fragment == nil, url.user == nil,
          url.port == nil, url.path.isEmpty || url.path == "/" else { continue }
        switch url.host {
        case "new": self.openEmptyShelf()
        case "clipboard": self.openEmptyShelf()?.ingest(.general)
        case "settings": self.showSettings()
        case "quit-if-idle": self.quitIfIdle()
        default: break
        }
      }
    }
  }
  /// Shows a new shelf at once from memory and saves it afterwards. The save is queued on the store
  /// worker immediately, so every later change to this shelf is ordered after it.
  @discardableResult func newShelf(near point: NSPoint? = nil, activate: Bool = true) -> ShelfController? {
    guard let store else { report(ShelfError("Shelf history is unavailable.")); return nil }
    let shelf = Shelf()
    do { try store.beginCreate(shelf) } catch { report(error); return nil }
    let saving = enqueueStore { try $0.create(shelf) }
    Task { [weak self] in
      do { _ = try await saving.value; self?.cleanAttachments() }
      catch {
        guard let self else { return }
        self.store?.cancelCreate(shelf.id)
        for controller in self.shelfControllers(shelf.id) { controller.retire() }
        self.controllers.removeValue(forKey: shelf.id); self.replicas.removeValue(forKey: shelf.id)
        self.report(error)
      }
    }
    return show(shelf.id, near: point ?? NSEvent.mouseLocation, activate: activate)
  }
  /// The shortcut, the menu's New Shelf, and `pos-shelf://new` summon an untouched empty shelf
  /// instead of stacking more of them; a shelf is created only when none exists.
  @discardableResult func openEmptyShelf(near point: NSPoint? = nil, activate: Bool = true) -> ShelfController? {
    let anchor = point ?? NSEvent.mouseLocation
    if let id = reusableEmptyShelf(near: anchor) { return show(id, near: anchor, activate: activate) }
    return newShelf(near: anchor, activate: activate)
  }
  func reusableEmptyShelf(near point: NSPoint) -> UUID? {
    let untitled = Shelf().name
    let candidates = (store?.shelves ?? []).filter { shelf in
      !shelf.closed && !shelf.pinned && shelf.items.isEmpty && shelf.name == untitled && imports.pendingCount(for: shelf.id) == 0
        && !shelfControllers(shelf.id).contains { $0.activeGesture || $0.window?.attachedSheet != nil }
    }
    let onDisplay = candidates.first { shelf in
      shelfControllers(shelf.id).contains { $0.window?.isVisible == true && ($0.display?.frame ?? $0.window?.screen?.frame)?.contains(point) == true }
    }
    return (onDisplay ?? candidates.first { controllers[$0.id] != nil } ?? candidates.first)?.id
  }
  @discardableResult func open(_ id: UUID, near point: NSPoint? = nil, activate: Bool = true) async -> ShelfController? {
    do {
      guard let shelf = store?.shelves.first(where: { $0.id == id }) else { throw ShelfError("Shelf no longer exists.") }
      if shelf.closed { try await withStore { try $0.update(id) { $0.closed = false } } }
    } catch { report(error); return nil }
    return show(id, near: point, activate: activate)
  }
  /// Presents an open shelf on every display without touching history. `activate` makes the
  /// non-activating panel key; it never activates the app, so the frontmost app keeps focus.
  @discardableResult func show(_ id: UUID, near point: NSPoint? = nil, activate: Bool = true) -> ShelfController? {
    if controllers[id] == nil {
      let display = preferredDisplay(in: currentDisplays(), near: point ?? NSEvent.mouseLocation)
      controllers[id] = ShelfController(app: self, id: id, display: display)
    }
    controllers[id]?.message = imports.message(for: id)
    synchronizeDisplays()
    let copies = shelfControllers(id)
    let displays = currentDisplays()
    let targetDisplay = preferredDisplay(in: displays, near: point ?? NSEvent.mouseLocation)?.id
    let target = copies.first(where: { $0.display?.id == targetDisplay }) ?? controllers[id]
    if !displays.isEmpty {
      for controller in copies where controller !== target { controller.present(activate: false) }
      target?.present(near: point, activate: activate)
    }
    return target
  }
  // MARK: Shake to open
  private(set) var shakeEnabled = true
  private var dragMonitors: [Any] = []
  var dragMonitorInstalled: Bool { !dragMonitors.isEmpty }
  /// Test seams; production reads AppKit's drag pasteboard and the pointer.
  lazy var dragPasteboard = NSPasteboard(name: .drag)
  var pointerLocation: @MainActor () -> NSPoint = { NSEvent.mouseLocation }
  private var dragBoardChangeCount: Int?
  private var dragBoardHasContent = false
  private(set) var dragPasteboardReads = 0
  /// Caches the preference and installs the drag monitors only while shaking can open a shelf.
  func applyShakeSetting() {
    shakeEnabled = defaults.object(forKey: "shake") == nil || defaults.bool(forKey: "shake")
    if shakeEnabled, dragMonitors.isEmpty {
      if let global = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDragged, handler: { [weak self] event in
        MainActor.assumeIsolated { self?.observeDrag(event) }
      }) { dragMonitors.append(global) }
      if let local = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDragged, handler: { [weak self] event in
        MainActor.assumeIsolated { self?.observeDrag(event) }; return event
      }) { dragMonitors.append(local) }
    } else if !shakeEnabled, !dragMonitors.isEmpty {
      for monitor in dragMonitors { NSEvent.removeMonitor(monitor) }
      dragMonitors.removeAll(); shake = ShelfShakeDetector()
    }
  }
  /// Runs for every drag event system-wide, so it does only motion math until a shake completes.
  func observeDrag(_ event: NSEvent) {
    guard shakeEnabled else { return }
    let point = pointerLocation()
    guard shake.feed(point, time: event.timestamp, dragging: true), dragCarriesShelfContent() else { return }
    // Reuse an empty shelf during a drag instead of opening duplicate panels.
    if let existing = allControllers.first(where: {
      $0.items.isEmpty && $0.pendingImages == 0 && $0.window?.isVisible == true
        && ($0.display?.frame ?? $0.window?.screen?.frame)?.contains(point) == true
    }) {
      existing.present(near: point, activate: false)
    } else { newShelf(near: point, activate: false) }
  }
  /// The drag pasteboard changes once per drag session, so its types are read at most once per drag.
  func dragCarriesShelfContent() -> Bool {
    let count = dragPasteboard.changeCount
    if count != dragBoardChangeCount {
      dragBoardChangeCount = count; dragPasteboardReads += 1
      dragBoardHasContent = !ShelfIngest.dragTypeSet.isDisjoint(with: dragPasteboard.types ?? [])
    }
    return dragBoardHasContent
  }
  func handleKey(_ event: NSEvent) -> NSEvent? {
    if recording {
      if event.keyCode == 53 { recording = false; shortcutButton?.title = shortcutLabel; return nil }
      let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
      guard !flags.intersection([.command, .option, .control]).isEmpty else { return nil }
      if (event.keyCode == 19 && flags == [.command, .shift]) || (event.keyCode == 9 && flags == [.command, .shift]) {
        shortcutButton?.title = "Reserved by screenshots / clipboard"; return nil
      }
      var mods: UInt32 = 0
      if flags.contains(.command) { mods |= UInt32(cmdKey) }; if flags.contains(.option) { mods |= UInt32(optionKey) }
      if flags.contains(.control) { mods |= UInt32(controlKey) }; if flags.contains(.shift) { mods |= UInt32(shiftKey) }
      let previous = ["key", "modifiers", "shortcutLabel"].map { ($0, defaults.object(forKey: $0)) }
      defaults.set(Int(event.keyCode), forKey: "key"); defaults.set(Int(mods), forKey: "modifiers")
      let title = (flags.contains(.control) ? "⌃" : "") + (flags.contains(.option) ? "⌥" : "") + (flags.contains(.shift) ? "⇧" : "") + (flags.contains(.command) ? "⌘" : "") + (event.keyCode == 49 ? "Space" : (event.charactersIgnoringModifiers?.uppercased() ?? "Key \(event.keyCode)"))
      defaults.set(title, forKey: "shortcutLabel"); recording = false; registerShortcut()
      if hotkey == nil {
        for (key, value) in previous { defaults.set(value, forKey: key) }
        registerShortcut()
        shortcutButton?.title = "In use; kept " + shortcutLabel
      } else { shortcutButton?.title = shortcutLabel }
      return nil
    }
    guard let shelf = allControllers.first(where: { $0.window?.isKeyWindow == true }), shelf.window?.attachedSheet == nil else { return event }
    let cmd = event.modifierFlags.contains(.command)
    switch event.keyCode {
    case 53: shelf.closeShelf(); return nil
    case 49: shelf.quickLook(); return nil
    case 51: shelf.removeAction(); return nil
    default: break
    }
    if cmd {
      switch event.charactersIgnoringModifiers?.lowercased() {
      case "v": _ = shelf.ingest(.general); return nil
      case "c": shelf.copyItems(); return nil
      case "a": shelf.selected = Set(shelf.items.map(\.id)); renderShelf(shelf.id); return nil
      case "w": shelf.closeShelf(); return nil
      case "n": newShelf(); return nil
      case "z" where !event.modifierFlags.contains(.shift): return shelf.undoRemoval() ? nil : event
      default: break
      }
    }
    return event
  }
  var shortcutLabel: String { defaults.string(forKey: "shortcutLabel") ?? "⌥⇧Space" }
  func registerShortcut() {
    if let hotkey { UnregisterEventHotKey(hotkey); self.hotkey = nil }
    if handler == nil {
      var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
      InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
        // Synchronous: the panel is on screen before the handler returns; history is saved afterwards.
        MainActor.assumeIsolated {
          _ = DropShelfApp.shared.openEmptyShelf(near: NSEvent.mouseLocation, activate: NSEvent.pressedMouseButtons & 1 == 0)
        }
        return noErr
      }, 1, &type, nil, &handler)
    }
    let code = defaults.object(forKey: "key") == nil ? 49 : UInt32(defaults.integer(forKey: "key"))
    let mods = defaults.object(forKey: "modifiers") == nil ? UInt32(optionKey | shiftKey) : UInt32(defaults.integer(forKey: "modifiers"))
    let result = RegisterEventHotKey(code, mods, EventHotKeyID(signature: 0x53484C46, id: 1), GetApplicationEventTarget(), 0, &hotkey)
    shortcutProblem = result == noErr ? nil : "Shortcut unavailable. Choose another in Settings."
    updateMenu()
  }
  func updateMenu() {
    menu.removeAllItems()
    func add(_ title: String, _ action: Selector, value: String? = nil) {
      let item = NSMenuItem(title: title, action: action, keyEquivalent: ""); item.target = self; item.representedObject = value; menu.addItem(item)
    }
    if let shortcutProblem { let item = NSMenuItem(title: shortcutProblem, action: nil, keyEquivalent: ""); menu.addItem(item) }
    if let storeRecovery {
      let item = NSMenuItem(title: "Shelf history was damaged and has been reset", action: nil, keyEquivalent: "")
      item.toolTip = storeRecovery.notice; menu.addItem(item)
      add("Show Damaged History in Finder", #selector(showRecoveredFiles))
    }
    if busy { add("Cancel Export", #selector(cancelExportAction)) }
    add("New Shelf · \(shortcutLabel)", #selector(newAction))
    add("Add Clipboard to New Shelf", #selector(clipboardAction))
    for (title, list) in [("Pinned", store?.shelves.filter(\.pinned) ?? []), ("Open", store?.shelves.filter { !$0.closed && !$0.pinned } ?? []), ("Recent", (store?.shelves.filter { $0.closed && !$0.pinned } ?? []).sorted { $0.updated > $1.updated })] {
      guard !list.isEmpty else { continue }
      menu.addItem(.separator()); menu.addItem(NSMenuItem(title: title, action: nil, keyEquivalent: ""))
      for shelf in list {
        let pending = imports.pendingCount(for: shelf.id)
        let status = pending > 0 ? " · adding \(pending)…" : ""
        add("\(shelf.name) · \(shelf.items.count) items" + status, #selector(reopen(_:)), value: shelf.id.uuidString)
      }
    }
    menu.addItem(.separator()); add("Settings…", #selector(settingsAction)); add("Quit Drop Shelf", #selector(quitAction))
    // Release every monitor's panel together, retaining only lightweight history.
    removeClosedControllers()
  }
  @objc func newAction() { openEmptyShelf() }
  @objc func clipboardAction() { openEmptyShelf()?.ingest(.general) }
  @objc func reopen(_ sender: NSMenuItem) { if let raw = sender.representedObject as? String, let id = UUID(uuidString: raw) { Task { await open(id) } } }
  @objc func settingsAction() { showSettings() }
  @objc func showRecoveredFiles() { if let files = storeRecovery?.keptFiles { NSWorkspace.shared.activateFileViewerSelecting(files) } }
  @objc func cancelExportAction() { cancelExport() }
  @objc func quitAction() {
    if busy {
      confirm("Stop the current export and quit?", detail: "Files already copied are kept. An unfinished ZIP is discarded.", action: "Stop and Quit", for: nil) { [weak self] stop in
        guard stop, let self, self.busy else { return }
        self.quitAfterExport = true; self.cancelExport()
      }
      return
    }
    guard !imports.isBusy && activeDragURLs.isEmpty else { report(ShelfError("Finish the current import or drag before quitting.")); return }
    // History writes and the attachment sweep are short; finish them instead of refusing.
    Task { await waitForStore(); terminator() }
  }
  // MARK: Quitting
  /// Idle for the launcher protocol: no shelf on screen or open, nothing being imported, copied,
  /// zipped, or dragged, and no dialog. Queued history writes are awaited rather than counted.
  var isIdle: Bool {
    !busy && !imports.isBusy && activeDragURLs.isEmpty && !hasProtectedInteraction && settings?.isVisible != true
      && NSApp.modalWindow == nil && !allControllers.contains { $0.window?.isVisible == true || $0.shelf?.closed == false }
  }
  /// `pos-shelf://quit-if-idle`: never shows UI or activates; quits with exit 0 only when idle.
  func quitIfIdle() {
    guard isIdle else { return }
    Task { [weak self] in
      guard let self else { return }
      await self.waitForStore()
      if self.isIdle && self.storeOperations == 0 { self.terminator() }
    }
  }
  /// True while the system is logging out, restarting, or shutting down.
  var sessionEnding = false
  private func noteSessionEnding() {
    sessionEnding = true
    // A cancelled logout must not leave later ordinary quits treated as session ends.
    DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in MainActor.assumeIsolated { self?.sessionEnding = false } }
  }
  static func isSessionEnd(_ event: NSAppleEventDescriptor?) -> Bool {
    guard let event, event.eventClass == AEEventClass(kCoreEventClass), event.eventID == AEEventID(kAEQuitApplication) else { return false }
    let keyword = AEKeyword(kAEQuitReason)
    guard let reason = event.attributeDescriptor(forKeyword: keyword) ?? event.paramDescriptor(forKeyword: keyword) else { return false }
    let code = reason.typeCodeValue != 0 ? reason.typeCodeValue : reason.enumCodeValue
    return [kAELogOut, kAEReallyLogOut, kAEShowRestartDialog, kAEShowShutdownDialog, kAERestart, kAEShutDown].map { OSType($0) }.contains(code)
  }
  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    // Logout, restart, and shutdown are never blocked: stop the export and let the session end.
    if sessionEnding || Self.isSessionEnd(NSAppleEventManager.shared().currentAppleEvent) {
      exportJob?.cancel(); return .terminateNow
    }
    return hasActiveWork ? .terminateCancel : .terminateNow
  }
  func applicationWillTerminate(_ notification: Notification) {
    exportJob?.cancel()
    for controller in allControllers { controller.closePreview(); controller.window?.orderOut(nil) }
    for observer in [displayObserver, defaultsObserver].compactMap({ $0 }) { NotificationCenter.default.removeObserver(observer) }
    displayObserver = nil; defaultsObserver = nil
    if let powerOffObserver { NSWorkspace.shared.notificationCenter.removeObserver(powerOffObserver); self.powerOffObserver = nil }
    for monitor in dragMonitors + [keyMonitor].compactMap({ $0 }) { NSEvent.removeMonitor(monitor) }
    dragMonitors.removeAll(); keyMonitor = nil
    if let hotkey { UnregisterEventHotKey(hotkey) }
  }
  func report(_ error: Error) {
    if let errorObserver { errorObserver(error); return }
    let alert = NSAlert(); alert.messageText = "Drop Shelf"; alert.informativeText = error.localizedDescription
    NSApp.activate(ignoringOtherApps: true); alert.runModal()
  }
  /// Asks before a destructive action: as a sheet on a shelf, otherwise as a modal alert.
  func confirm(_ message: String, detail: String, action: String, for window: NSWindow?, completion: @escaping (Bool) -> Void) {
    if let confirmationHandler { confirmationHandler(message, completion); return }
    let alert = NSAlert(); alert.messageText = message; alert.informativeText = detail
    alert.addButton(withTitle: action); alert.addButton(withTitle: "Cancel")
    alert.buttons.first?.hasDestructiveAction = true
    NSApp.activate(ignoringOtherApps: true)
    guard let window else { completion(alert.runModal() == .alertFirstButtonReturn); return }
    alert.beginSheetModal(for: window) { [weak self] response in
      completion(response == .alertFirstButtonReturn); self?.synchronizeDisplays()
    }
  }
  func showSettings() {
    if settings == nil {
      let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 430, height: 280), styleMask: [.titled, .closable], backing: .buffered, defer: false)
      window.title = "Drop Shelf Settings"; window.isReleasedWhenClosed = false; window.delegate = self
      let content = window.contentView!
      let heading = NSTextField(wrappingLabelWithString: "Collect files, images, text, and links. The same shelf stays available across apps and screens; drag items out when ready.")
      heading.frame = NSRect(x: 20, y: 209, width: 390, height: 50); content.addSubview(heading)
      let shakeButton = NSButton(checkboxWithTitle: "Shake to open a shelf", target: self, action: #selector(toggleShake(_:)))
      shakeButton.state = shakeEnabled ? .on : .off; shakeButton.frame = NSRect(x: 20, y: 175, width: 390, height: 25); content.addSubview(shakeButton)
      let login = NSButton(checkboxWithTitle: "Start Drop Shelf at login", target: self, action: #selector(toggleLogin(_:)))
      login.state = FileManager.default.fileExists(atPath: loginURL.path) ? .on : .off
      login.frame = NSRect(x: 20, y: 143, width: 390, height: 25); content.addSubview(login)
      let label = NSTextField(labelWithString: "New shelf shortcut:"); label.frame = NSRect(x: 20, y: 107, width: 160, height: 24); content.addSubview(label)
      let shortcut = NSButton(title: shortcutLabel, target: self, action: #selector(recordShortcut))
      shortcut.bezelStyle = .rounded; shortcut.frame = NSRect(x: 180, y: 102, width: 215, height: 32); content.addSubview(shortcut); shortcutButton = shortcut
      let footer = NSTextField(wrappingLabelWithString: "Drag out to copy. Space previews; ⌘V adds the clipboard; ⌘C copies; Delete removes selected items (⌘Z undoes). Up to 200 items per shelf and 10 recent shelves. Shelf content is stored locally; nothing uploads automatically.")
      footer.font = .systemFont(ofSize: 11); footer.textColor = .secondaryLabelColor
      footer.frame = NSRect(x: 20, y: 15, width: 390, height: 77); content.addSubview(footer)
      settings = window
    }
    settings?.center(); settings?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
  }
  func windowWillClose(_ notification: Notification) {
    if notification.object as? NSWindow === settings { recording = false; shortcutButton?.title = shortcutLabel }
  }
  // MARK: Attachment cleanup
  var cleanupDelay: TimeInterval = 1
  private var cleanupTimer: DispatchWorkItem?
  private var cleanupTask: Task<Void, Never>?
  private var cleanupRequested = false
  private(set) var cleanupSweeps = 0
  /// Coalesces the requests that follow most actions into one low-priority sweep in flight at a
  /// time. Protected files are collected when the sweep starts, not when it was requested.
  func cleanAttachments() {
    if cleanupTask != nil { cleanupRequested = true; return }
    guard cleanupTimer == nil else { return }
    let timer = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.startCleanup() } }
    cleanupTimer = timer
    DispatchQueue.main.asyncAfter(deadline: .now() + cleanupDelay, execute: timer)
  }
  private func startCleanup() {
    cleanupTimer?.cancel(); cleanupTimer = nil
    guard cleanupTask == nil else { cleanupRequested = true; return }
    let protected = protectedAttachmentURLs()
    cleanupSweeps += 1
    let sweep = enqueueStore(priority: .utility) { $0.cleanAttachments(protecting: protected) }
    cleanupTask = Task { [weak self] in
      _ = try? await sweep.value
      guard let self else { return }
      self.cleanupTask = nil
      if self.cleanupRequested { self.cleanupRequested = false; self.cleanAttachments() }
    }
  }
  /// Runs a scheduled sweep now and waits until no sweep is pending.
  func flushAttachmentCleanup() async {
    while true {
      if cleanupTimer != nil { startCleanup() }
      guard let task = cleanupTask else { return }
      await task.value
    }
  }
  func protectedAttachmentURLs() -> [URL] {
    exportURLs + clipboardFileReferences() + activeDragURLs.values.flatMap { $0 } + imports.protectedFileURLs + (lastRemoval?.protectedURLs ?? [])
  }
  /// Injected in tests so they never read or write the user's clipboard.
  var generalPasteboard = NSPasteboard.general
  private var clipboardChangeCount: Int?
  private var clipboardFiles: [URL] = []
  private(set) var clipboardContentReads = 0
  /// Shelf copies are remembered when written, so they are protected without reading them back.
  func rememberClipboardCopy(_ files: [URL], on board: NSPasteboard) {
    guard board.name == generalPasteboard.name else { return }
    clipboardChangeCount = board.changeCount; clipboardFiles = files
  }
  /// File URLs on the clipboard keep their backing attachments. Contents are read only after the
  /// clipboard changed and advertises file URLs, and never where macOS would show a paste alert.
  func clipboardFileReferences() -> [URL] {
    let board = generalPasteboard, count = board.changeCount
    guard count != clipboardChangeCount else { return clipboardFiles }
    clipboardChangeCount = count; clipboardFiles = []
    guard board.types?.contains(.fileURL) == true else { return [] }
    if #available(macOS 15.4, *), board.name == .general, board.accessBehavior != .alwaysAllow { return [] }
    clipboardContentReads += 1
    clipboardFiles = (board.pasteboardItems ?? []).prefix(200).compactMap { item -> URL? in
      guard let value = item.string(forType: .fileURL), let url = URL(string: value), url.isFileURL else { return nil }
      return url
    }
    return clipboardFiles
  }
  // MARK: Removal and undo
  private(set) var lastRemoval: ShelfRemoval?
  var undoWindow: TimeInterval = 10
  /// Starts a removal's undo window. A new removal ends the previous window, releasing its files.
  func beginRemoval(_ removal: ShelfRemoval) {
    endRemoval(lastRemoval)
    lastRemoval = removal
    let expiry = DispatchWorkItem { [weak self, weak removal] in
      MainActor.assumeIsolated { if let removal { self?.endRemoval(removal) } }
    }
    removal.expiry = expiry
    DispatchQueue.main.asyncAfter(deadline: .now() + undoWindow, execute: expiry)
  }
  func endRemoval(_ removal: ShelfRemoval?) {
    guard let removal else { return }
    removal.expiry?.cancel(); removal.expiry = nil
    if lastRemoval === removal { lastRemoval = nil }
    let copies = shelfControllers(removal.shelfID)
    if copies.first?.message == removal.hint { refreshShelf(removal.shelfID, message: imports.message(for: removal.shelfID)) }
    cleanAttachments()
  }
  @objc func toggleShake(_ sender: NSButton) { defaults.set(sender.state == .on, forKey: "shake"); applyShakeSetting() }
  @objc func recordShortcut() { recording = true; shortcutButton?.title = "Press shortcut; Esc cancels" }
  /// The LaunchAgent shared with the setup script: launchd restarts crashes, not deliberate quits.
  static func loginAgent(executable: String) -> [String: Any] {
    ["Label": bundleID, "ProgramArguments": [executable, "--background"], "RunAtLoad": true,
     "KeepAlive": ["SuccessfulExit": false], "ProcessType": "Interactive", "ThrottleInterval": 30,
     "LimitLoadToSessionType": "Aqua"]
  }
  /// ON writes the agent atomically; OFF only deletes it. Never bootstraps or boots out from here.
  func setStartAtLogin(_ enabled: Bool) throws {
    let fm = FileManager.default
    if enabled {
      guard let executable = Bundle.main.executablePath else { throw ShelfError("Drop Shelf could not locate its executable.") }
      try fm.createDirectory(at: loginURL.deletingLastPathComponent(), withIntermediateDirectories: true)
      try PropertyListSerialization.data(fromPropertyList: Self.loginAgent(executable: executable), format: .xml, options: 0).write(to: loginURL, options: .atomic)
    } else {
      do { try fm.removeItem(at: loginURL) } catch let error as CocoaError where error.code == .fileNoSuchFile {}
    }
  }
  @objc func toggleLogin(_ sender: NSButton) {
    do { try setStartAtLogin(sender.state == .on) }
    catch { sender.state = sender.state == .on ? .off : .on; report(error) }
  }
  // MARK: Export
  func export(_ items: [ShelfItem], to folder: URL, zip: Bool, controller: ShelfController) {
    guard !busy else { return }; busy = true
    let job = ShelfExportJob(); exportJob = job
    exportURLs = items.compactMap { $0.resolvedURL() }
    let shelfID = controller.id, timeout = exportTimeout
    refreshShelf(shelfID, message: zip ? "Creating ZIP… (⋯ menu cancels)" : "Copying… (⋯ menu cancels)")
    DispatchQueue.global(qos: .utility).async { [weak self] in
      let result: Result<[URL], Error> = Result {
        if !zip { return try ShelfFiles.export(items, to: folder, job: job) }
        return [try ShelfFiles.archive(items, to: folder, job: job, timeout: timeout)]
      }
      DispatchQueue.main.async {
        guard let self else { return }; self.busy = false; self.exportURLs = []; self.exportJob = nil; self.cleanAttachments()
        if self.quitAfterExport { self.quitAfterExport = false; self.terminator(); return }
        switch result {
        case .success(let urls): self.refreshShelf(shelfID, message: "Saved \(urls.count) item\(urls.count == 1 ? "" : "s")"); NSWorkspace.shared.activateFileViewerSelecting(urls)
        case .failure where job.isCancelled: self.refreshShelf(shelfID, message: zip ? "ZIP cancelled." : "Copy cancelled; items already copied were kept.")
        case .failure(let error): self.refreshShelf(shelfID, message: "Some items may have copied; originals are unchanged."); self.report(error)
        }
      }
    }
  }
  func cancelExport() { exportJob?.cancel() }
}
