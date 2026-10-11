import AppKit
import Carbon
import ScreenCaptureKit
import UniformTypeIdentifiers

@MainActor final class StudioApp: NSObject, NSApplicationDelegate {
  static let shared = StudioApp()
  let capture = CaptureEngine()
  var controllers: [NSWindowController] = []
  var operations = 0, receivedCommand = false, recovered = false
  /// `quit-if-idle` can arrive before launch finishes; it is decided once the app is up.
  var launched = false, quitWhenLaunched = false
  var chooser: NSWindowController?
  var chooserObserver: NSObjectProtocol?
  var pinItem: NSStatusItem?
  /// The regular app that was active before this helper took focus; it gets focus back afterwards.
  var previousApp: NSRunningApplication?
  let notice = NoticePanel()
  // Resident mode keeps the process alive so ⌘⇧2 opens the area selector instantly.
  // A bare launch (Finder, or macOS "Quit & Reopen" after a permission change) also stays
  // resident so ⌘⇧2 keeps working; Raycast launches always carry a pos-screenshot:// URL.
  lazy var resident = CommandLine.arguments.contains("--background") || CommandLine.arguments.count == 1
  var hotkey: EventHotKeyRef?, hotkeyHandler: EventHandlerRef?
  var hotkeyProblem: String?
  let commands: Set<String> = [
    "capture", "area", "window", "display", "repeat", "delay", "scroll", "text", "record", "open",
    "clipboard", "settings", "unlock-pins",
  ]
  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.accessory)
    if resident,
      NSRunningApplication.runningApplications(
        withBundleIdentifier: "com.productivity-os.screenshot-studio"
      ).contains(where: { $0.processIdentifier != getpid() })
    {
      NSApp.terminate(nil)
      return
    }
    menus()
    if resident { registerHotkey() }
    trackFrontmostApp()
    notice.hidden = { [weak self] in self?.idle() }
    launched = true
    if quitWhenLaunched { quitIfIdle() }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
      guard let self else { return }
      recover()
      if !receivedCommand && !CommandLine.arguments.contains("--background") {
        let command = CommandLine.arguments.dropFirst().first ?? "capture"
        dispatch(command)
      }
    }
  }
  /// Registers ⌘⇧2 (kVK_ANSI_2 = 19) for area capture.
  func registerHotkey() {
    if hotkeyHandler == nil {
      var event = EventTypeSpec(
        eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
      InstallEventHandler(
        GetApplicationEventTarget(),
        { _, _, _ in
          // Application-target Carbon events arrive on the main thread: start without a task hop.
          if Thread.isMainThread {
            MainActor.assumeIsolated { StudioApp.shared.hotkeyPressed() }
          } else {
            Task { @MainActor in StudioApp.shared.hotkeyPressed() }
          }
          return noErr
        }, 1, &event, nil, &hotkeyHandler)
    }
    if let hotkey { UnregisterEventHotKey(hotkey) }
    hotkey = nil
    let status = RegisterEventHotKey(
      UInt32(kVK_ANSI_2), UInt32(cmdKey | shiftKey),
      EventHotKeyID(signature: 0x504F_5353, id: 1), GetApplicationEventTarget(), 0, &hotkey)
    hotkeyProblem = status == noErr ? nil : "⌘⇧2 is already used by another app."
    if let hotkeyProblem { NSLog("Screenshot Studio: %@", hotkeyProblem) }
  }
  func hotkeyPressed() {
    // A second ⌘⇧2 while selecting is ignored rather than reported as an error.
    guard operations == 0, capture.selection == nil else { return }
    begin("area")
  }
  func application(_ application: NSApplication, open urls: [URL]) {
    for url in urls {
      if url.scheme == "pos-screenshot",
        let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
        parts.host == "quit-if-idle", parts.queryItems == nil, parts.path.isEmpty
      {
        receivedCommand = true
        quitIfIdle()
      } else if url.scheme == "pos-screenshot",
        let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
        let command = parts.host, commands.contains(command), parts.queryItems == nil,
        parts.path.isEmpty
      {
        receivedCommand = true
        dispatch(command)
      } else if url.isFileURL {
        receivedCommand = true
        openFile(url)
      }
    }
  }
  func dispatch(_ command: String) {
    guard commands.contains(command) else {
      report(StudioError("Unsupported screenshot command"))
      idle()
      return
    }
    switch command {
    case "settings": settings()
    case "open":
      let panel = NSOpenPanel()
      panel.allowedContentTypes = [.image, UTType(filenameExtension: "posshot") ?? .directory]
      panel.canChooseDirectories = true
      if panel.runModal() == .OK, let url = panel.url { openFile(url) } else { idle() }
    case "clipboard":
      do {
        guard let image = NSImage(pasteboard: .general),
          let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { throw StudioError("The clipboard does not contain an image") }
        edit(try StudioDocument(image: cg))
      } catch {
        report(error)
        idle()
      }
    case "unlock-pins": unlockPins()
    case "capture": showChooser()
    default: begin(command)
    }
  }
  func begin(_ command: String) {
    guard operations == 0, capture.selection == nil,
      !controllers.contains(where: {
        $0 is ScrollController || ($0 as? RecordingController)?.finished == false
      })
    else {
      report(StudioError("Finish the current capture or recording first"))
      return
    }
    operations += 1
    chooser?.close()
    chooser = nil
    Task {
      defer {
        operations -= 1
        idle()
      }
      do {
        if command == "delay" {
          let delay = UserDefaults.standard.integer(forKey: "delay")
          try await Task.sleep(nanoseconds: UInt64(max(1, delay)) * 1_000_000_000)
        }
        var mode =
          command == "record" || command == "scroll" || command == "text" || command == "delay"
          ? "area" : command
        if command == "record" {
          let choice = NSAlert()
          choice.messageText = "What would you like to record?"
          ["Area", "Window", "Display", "Cancel"].forEach { choice.addButton(withTitle: $0) }
          let index = choice.runModal().rawValue - 1000
          guard index < 3 else { return }
          mode = ["area", "window", "display"][index]
        }
        guard let target = try await capture.choose(mode: mode) else { return }
        if command == "record" {
          capture.frozenSelection = nil
          let controller = try RecordingController(target: target)
          keep(controller)
          return
        }
        let image: CGImage
        if command != "scroll", let frozen = capture.frozenSelection {
          image = frozen
        } else {
          image = try await capture.capture(target)
        }
        capture.frozenSelection = nil
        if command == "text" {
          let lines = try await ImageWorker.shared.run { try VisionTools.recognize(image) }
          guard !lines.isEmpty else { throw StudioError("No text was recognized") }
          NSPasteboard.general.clearContents()
          NSPasteboard.general.setString(
            lines.map(\.text).joined(separator: "\n"), forType: .string)
          return
        }
        if command == "scroll" {
          let alert = NSAlert()
          alert.messageText = "Scrolling capture"
          alert.informativeText =
            "Manual mode: scroll the target yourself, then Add Frame. Automatic mode requires Accessibility permission."
          ["Vertical Auto", "Vertical Manual", "Horizontal Auto", "Horizontal Manual", "Cancel"]
            .forEach { alert.addButton(withTitle: $0) }
          let choice = alert.runModal().rawValue - 1000
          guard choice < 4 else { return }
          let controller = try ScrollController(
            target: target, image: image, horizontal: choice >= 2, manual: choice % 2 == 1)
          keep(controller)
          return
        }
        try preview(StudioDocument(image: image, scale: target.scale))
      } catch { report(error) }
    }
  }
  func showChooser() {
    if let chooser {
      chooser.showWindow(nil)
      NSApp.activate(ignoringOtherApps: true)
      return
    }
    let window = NSWindow(
      contentRect: CGRect(x: 0, y: 0, width: 680, height: 240), styleMask: [.titled, .closable],
      backing: .buffered, defer: false)
    window.title = "Screenshot Studio"
    window.isReleasedWhenClosed = false
    let buttons: [(String, String, String)] = [
      ("Area", "viewfinder", "area"), ("Window", "macwindow", "window"),
      ("Display", "display", "display"), ("Scroll", "scroll", "scroll"),
      ("Text", "text.viewfinder", "text"), ("Record", "record.circle", "record"),
    ]
    let heading = label("Capture something.", size: 26)
    let stack = column(
      [
        heading,
        label(
          "Precise captures. Clear explanations. Everything stays on your Mac.", secondary: true),
        row(
          buttons.map { title, symbol, command in
            ClickButton(title, symbol: symbol) { [weak self] in self?.begin(command) }
          }),
        row([
          ClickButton("Open Image") { [weak self] in
            self?.chooser?.close()
            self?.chooser = nil
            self?.dispatch("open")
          },
          ClickButton("Clipboard") { [weak self] in
            self?.chooser?.close()
            self?.chooser = nil
            self?.dispatch("clipboard")
          }, ClickButton("Settings") { [weak self] in self?.settings() },
        ]),
      ], spacing: 18)
    fill(stack, in: window.contentView!, inset: 24)
    window.center()
    chooser = NSWindowController(window: window)
    chooser?.showWindow(nil)
    NSApp.activate(ignoringOtherApps: true)
    chooserObserver = NotificationCenter.default.addObserver(
      forName: NSWindow.willCloseNotification, object: window, queue: .main
    ) { [weak self] _ in
      Task { @MainActor [weak self] in
        guard let self else { return }
        if let observer = chooserObserver { NotificationCenter.default.removeObserver(observer) }
        chooserObserver = nil
        chooser = nil
        idle()
      }
    }
  }
  func keep(_ controller: NSWindowController) {
    controllers.append(controller)
    controller.showWindow(nil)
    controller.window?.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }
  func preview(_ shot: StudioDocument) throws { keep(try PreviewController(shot)) }
  func edit(_ shot: StudioDocument) { keep(EditorController(shot)) }
  func pin(_ shot: StudioDocument) throws {
    keep(try PinController(shot))
    ensurePinMenu()
  }
  func release(_ controller: NSWindowController, shot: StudioDocument? = nil) {
    controllers.removeAll { $0 === controller }
    if let shot,
      !controllers.contains(where: {
        ($0 as? EditorController)?.shot === shot || ($0 as? PreviewController)?.shot === shot
          || ($0 as? PinController)?.shot === shot || ($0 as? ScrollController)?.shot === shot
      })
    {
      shot.discard()
    }
    if !controllers.contains(where: { $0 is PinController }), let pinItem {
      NSStatusBar.system.removeStatusItem(pinItem)
      self.pinItem = nil
    }
    idle()
  }
  /// Nothing open, in flight or unsaved: no window, capture, recording, scroll, pin, document, dialog
  /// or notice. Shared by the on-demand exit and `quit-if-idle`.
  var isIdle: Bool {
    operations == 0 && controllers.isEmpty && chooser == nil && capture.selection == nil
      && NSApp.modalWindow == nil && !notice.isShowing
  }
  func idle() {
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
      guard let self, isIdle else { return }
      if resident { restoreFocus() } else { NSApp.terminate(nil) }
    }
  }
  /// `pos-screenshot://quit-if-idle` (launcher protocol 1): never shows UI or activates; exits 0 only
  /// when idle, otherwise does nothing (the updater then reports busy).
  func quitIfIdle() {
    guard launched else {
      quitWhenLaunched = true
      return
    }
    if isIdle { NSApp.terminate(nil) }
  }
  func trackFrontmostApp() {
    remember(NSWorkspace.shared.frontmostApplication)
    NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
    ) { note in
      let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
      MainActor.assumeIsolated { StudioApp.shared.remember(app) }
    }
  }
  func remember(_ app: NSRunningApplication?) {
    // Accessory apps (Raycast, menu bar tools) are skipped: activating them can reopen their panels.
    guard let app, app.processIdentifier != getpid(), app.activationPolicy == .regular else { return }
    previousApp = app
  }
  /// The resident helper stays alive after its last window closes; without this, focus would stay on
  /// a windowless app instead of returning to where the capture started.
  func restoreFocus() {
    guard NSApp.isActive, let app = previousApp, !app.isTerminated else { return }
    NSApp.yieldActivation(to: app)
    app.activate(from: NSRunningApplication.current, options: [])
  }
  func mayClose(_ shot: StudioDocument) -> Bool {
    if shot.saved { return true }
    let alert = NSAlert()
    alert.messageText = "Save this capture?"
    alert.informativeText = "Discard removes the temporary capture and its edits."
    ["Save", "Discard", "Cancel"].forEach { alert.addButton(withTitle: $0) }
    switch alert.runModal() {
    case .alertFirstButtonReturn:
      do { return try save(shot) } catch {
        report(error)
        return false
      }
    case .alertSecondButtonReturn: return true
    default: return false
    }
  }
  func exportImage(_ shot: StudioDocument) throws -> CGImage {
    let maxSide = UserDefaults.standard.double(forKey: "exportSide")
    return try Renderer.image(shot.scene, store: shot.store, maxSide: maxSide > 0 ? maxSide : nil)
  }
  func copy(_ shot: StudioDocument) throws {
    let image = try exportImage(shot)
    let rep = NSBitmapImageRep(cgImage: image)
    guard let data = rep.representation(using: .png, properties: [:]) else {
      throw StudioError("Could not encode clipboard image")
    }
    NSPasteboard.general.clearContents()
    guard NSPasteboard.general.setData(data, forType: .png) else {
      throw StudioError("Clipboard could not accept the image")
    }
  }
  func dragFile(_ shot: StudioDocument) throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "ProductivityOS-Screenshot-Exports")
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let url = directory.appendingPathComponent(UUID().uuidString + ".png")
    try encode(exportImage(shot), to: url, type: UTType.png.identifier)
    return url
  }
  func save(_ shot: StudioDocument, format: String = "png") throws -> Bool {
    guard let url = chooseSave(extension: format) else { return false }
    let image = try exportImage(shot)
    if format == "pdf" {
      let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
      var media = bounds
      guard let context = CGContext(url as CFURL, mediaBox: &media, nil) else {
        throw StudioError("Cannot create PDF")
      }
      context.beginPDFPage(nil)
      context.draw(image, in: bounds)
      context.endPDFPage()
      context.closePDF()
    } else {
      try encode(
        image, to: url, type: format == "jpg" ? UTType.jpeg.identifier : UTType.png.identifier,
        quality: UserDefaults.standard.double(forKey: "jpegQuality"))
    }
    shot.saved = true
    return true
  }
  func openFile(_ url: URL) {
    do {
      if url.pathExtension == "posshot" {
        edit(try StudioDocument(project: url))
      } else {
        do { edit(try StudioDocument(image: loadImage(url))) } catch {
          if confirm(
            "Open a smaller version?", error.localizedDescription, action: "Downscale to 8,000 px")
          {
            edit(try StudioDocument(image: loadImage(url, maxSide: 8000)))
          }
        }
      }
    } catch { report(error) }
    idle()
  }
  func report(_ error: Error) {
    let alert = NSAlert()
    alert.messageText = "Screenshot Studio"
    alert.informativeText = error.localizedDescription
    alert.alertStyle = .warning
    alert.runModal()
    // An on-demand launch whose last step was this alert still exits once it is dismissed.
    idle()
  }
  /// Non-modal and non-activating, for problems that need no decision (e.g. a capture that timed out).
  func notify(_ message: String) { notice.show(message) }
  func recover() {
    guard !recovered else { return }
    recovered = true
    for directory in SessionStore.recoverable() {
      if confirm(
        "Recover unfinished capture?",
        "An editing session was interrupted. It has not been saved permanently.", action: "Recover")
      {
        do { edit(try StudioDocument(project: directory, recovering: true)) } catch {
          report(error)
        }
      } else {
        try? FileManager.default.removeItem(at: directory)
      }
    }
    let exports = FileManager.default.temporaryDirectory.appendingPathComponent(
      "ProductivityOS-Screenshot-Exports")
    for url
      in (try? FileManager.default.contentsOfDirectory(
        at: exports, includingPropertiesForKeys: [.creationDateKey])) ?? []
    {
      if let date = (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate,
        Date().timeIntervalSince(date) > 86_400
      {
        try? FileManager.default.removeItem(at: url)
      }
    }
  }
  func settings() {
    let alert = NSAlert()
    alert.messageText = "Screenshot settings"
    alert.informativeText =
      (hotkeyProblem ?? "⌘⇧2 captures an area.")
      + " Raycast commands cover the other capture modes. Screenshots and recognition remain local."
    let cursor = NSButton(checkboxWithTitle: "Include pointer", target: nil, action: nil)
    let shadow = NSButton(checkboxWithTitle: "Include window shadow", target: nil, action: nil)
    cursor.state = UserDefaults.standard.bool(forKey: "cursor") ? .on : .off
    shadow.state = UserDefaults.standard.bool(forKey: "shadow") ? .on : .off
    let delay = NSTextField(string: String(UserDefaults.standard.integer(forKey: "delay")))
    let dimensions = NSTextField(string: "")
    let ratio = NSTextField(string: "")
    if let fixed = UserDefaults.standard.array(forKey: "fixedCapture") as? [Double],
      fixed.count == 2
    {
      dimensions.stringValue = "\(Int(fixed[0])) x \(Int(fixed[1]))"
    }
    let savedRatio = UserDefaults.standard.double(forKey: "captureRatio")
    if savedRatio > 0 { ratio.stringValue = "\(savedRatio):1" }
    dimensions.placeholderString = "Optional width x height in pixels"
    ratio.placeholderString = "Optional ratio, e.g. 16:9"
    let stack = column([
      cursor, shadow, label("Capture delay (seconds, 1–30)"), delay, label("Fixed area dimensions"),
      dimensions, label("Area aspect ratio"), ratio,
    ])
    stack.frame = CGRect(x: 0, y: 0, width: 360, height: 240)
    alert.accessoryView = stack
    alert.addButton(withTitle: "Save")
    alert.addButton(withTitle: "Cancel")
    if alert.runModal() == .alertFirstButtonReturn {
      UserDefaults.standard.set(cursor.state == .on, forKey: "cursor")
      UserDefaults.standard.set(shadow.state == .on, forKey: "shadow")
      UserDefaults.standard.set(min(30, max(1, delay.integerValue)), forKey: "delay")
      let values = dimensions.stringValue.lowercased().split(separator: "x").compactMap {
        Double($0.trimmingCharacters(in: .whitespaces))
      }
      capture.fixedSize =
        values.count == 2 && values.allSatisfy { $0 > 0 && $0 <= 60000 }
        ? CGSize(width: values[0], height: values[1]) : nil
      let parts = ratio.stringValue.split(separator: ":").compactMap { Double($0) }
      capture.ratio =
        parts.count == 2 && parts.allSatisfy { $0 > 0 && $0.isFinite } ? parts[0] / parts[1] : nil
      UserDefaults.standard.set(
        capture.fixedSize.map { [$0.width, $0.height] }, forKey: "fixedCapture")
      UserDefaults.standard.set(capture.ratio ?? 0, forKey: "captureRatio")
    }
    idle()
  }
  func ensurePinMenu() {
    guard pinItem == nil else { return }
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    item.button?.image = NSImage(
      systemSymbolName: "pin", accessibilityDescription: "Screenshot references")
    let menu = NSMenu()
    let unlock = NSMenuItem(
      title: "Unlock All References", action: #selector(unlockPins), keyEquivalent: "")
    unlock.target = self
    menu.addItem(unlock)
    let close = NSMenuItem(
      title: "Close All References", action: #selector(closePins), keyEquivalent: "")
    close.target = self
    menu.addItem(close)
    item.menu = menu
    pinItem = item
  }
  @objc func unlockPins() {
    for controller in controllers where controller is PinController {
      controller.window?.ignoresMouseEvents = false
      controller.window?.makeKeyAndOrderFront(nil)
    }
  }
  @objc func closePins() {
    for controller in controllers.filter({ $0 is PinController }) { controller.window?.close() }
  }
  func menus() {
    let main = NSMenu()
    let app = NSMenu()
    let file = NSMenu()
    let edit = NSMenu()
    let root = NSMenuItem()
    root.submenu = app
    main.addItem(root)
    app.addItem(
      withTitle: "Quit Screenshot Studio", action: #selector(NSApplication.terminate(_:)),
      keyEquivalent: "q")
    let f = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
    f.submenu = file
    main.addItem(f)
    let capture = NSMenuItem(
      title: "New Capture", action: #selector(newCapture), keyEquivalent: "n")
    capture.target = self
    file.addItem(capture)
    let e = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
    e.submenu = edit
    main.addItem(e)
    edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
    edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
    edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
    edit.addItem(
      withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
    NSApp.mainMenu = main
  }
  @objc func newCapture() { dispatch("capture") }
  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    if operations > 0
      || controllers.contains(where: {
        ($0 as? RecordingController)?.stream != nil || ($0 as? EditorController)?.busy == true
          || ($0 as? RecordingController)?.busy == true
          || ($0 as? ScrollController)?.busy == true
      })
    {
      return .terminateCancel
    }
    var seen = Set<ObjectIdentifier>()
    for c in controllers {
      if let recording = c as? RecordingController, let window = recording.window,
        !recording.windowShouldClose(window)
      {
        return .terminateCancel
      }
      let d =
        (c as? EditorController)?.shot ?? (c as? PreviewController)?.shot
        ?? (c as? PinController)?.shot ?? (c as? ScrollController)?.shot
      if let d, seen.insert(ObjectIdentifier(d)).inserted, !mayClose(d) { return .terminateCancel }
    }
    for c in controllers { c.window?.close() }
    return .terminateNow
  }
}
