import AppKit
import CoreGraphics

@MainActor final class HealthButton: NSButton {
  let handler: () -> Void
  init(_ title: String, action: @escaping () -> Void) {
    handler = action; super.init(frame: .zero)
    self.title = title; bezelStyle = .rounded; target = self; self.action = #selector(invoke)
  }
  required init?(coder: NSCoder) { fatalError() }
  @objc func invoke() { handler() }
}
@MainActor final class HealthSettingsBackground: NSView {
  override var isOpaque: Bool { true }
  override func draw(_ dirtyRect: NSRect) {
    NSColor.windowBackgroundColor.setFill()
    bounds.fill()
  }
  override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
}
@MainActor final class HealthPanel: NSPanel {
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }
}
@MainActor final class HealthPopup: NSWindowController {
  unowned let app: HealthApp
  var kinds = Set<BreakKind>()
  var preview = false
  var expiration: Timer?
  init(app: HealthApp) {
    self.app = app
    let panel = HealthPanel(contentRect: NSRect(x: 0, y: 0, width: 380, height: 220), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    panel.title = "Health Break Reminder"; panel.isOpaque = false; panel.backgroundColor = .clear
    panel.level = .floating; panel.hasShadow = true; panel.hidesOnDeactivate = false
    panel.isReleasedWhenClosed = false; panel.isMovableByWindowBackground = true
    panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
    super.init(window: panel)
  }
  required init?(coder: NSCoder) { fatalError() }
  func show(_ kinds: Set<BreakKind>, preview: Bool = false) {
    self.kinds = kinds; self.preview = preview
    let ordered = BreakKind.allCases.filter { kinds.contains($0) }
    let height = CGFloat(138 + ordered.count * 72)
    let root = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 380, height: height))
    root.material = .hudWindow; root.blendingMode = .behindWindow; root.state = .active
    root.wantsLayer = true; root.layer?.cornerRadius = 20; root.layer?.masksToBounds = true
    func label(_ text: String, _ frame: NSRect, size: CGFloat, bold: Bool = false) -> NSTextField {
      let view = NSTextField(wrappingLabelWithString: text); view.frame = frame
      view.font = .systemFont(ofSize: size, weight: bold ? .semibold : .regular)
      root.addSubview(view); return view
    }
    _ = label(preview ? "A moment for you · Preview" : "A moment for you", NSRect(x: 22, y: height - 45, width: 320, height: 24), size: 19, bold: true)
    for (index, kind) in ordered.enumerated() {
      let y = height - 65 - CGFloat(index + 1) * 72
      let icon = NSImageView(frame: NSRect(x: 24, y: y + 20, width: 30, height: 30))
      icon.image = NSImage(systemSymbolName: kind.symbol, accessibilityDescription: kind.title)
      icon.contentTintColor = .systemTeal; root.addSubview(icon)
      _ = label(kind.title, NSRect(x: 68, y: y + 35, width: 288, height: 20), size: 13, bold: true)
      let detail = label(kind.detail, NSRect(x: 68, y: y - 1, width: 288, height: 36), size: 12)
      detail.textColor = .secondaryLabelColor
    }
    let done = HealthButton(preview ? "Close Preview" : "Done") { [weak self] in self?.finish(snooze: false) }
    done.frame = NSRect(x: 20, y: 27, width: 160, height: 32); root.addSubview(done)
    let later = HealthButton("Snooze 5 min") { [weak self] in self?.finish(snooze: true) }
    later.frame = NSRect(x: 195, y: 27, width: 165, height: 32); root.addSubview(later)
    let foot = label(preview ? "Preview does not change your timers" : "Snoozes after 45 seconds · No need to stop typing", NSRect(x: 20, y: 7, width: 340, height: 16), size: 10)
    foot.textColor = .secondaryLabelColor; foot.alignment = .center
    window?.setContentSize(root.frame.size); window?.contentView = root
    let pointer = NSEvent.mouseLocation
    let screen = NSScreen.screens.first { $0.frame.contains(pointer) } ?? NSScreen.main
    if let frame = screen?.visibleFrame {
      let x = app.clock.preferences.centered ? frame.midX - 190 : frame.maxX - 400
      let y = app.clock.preferences.centered ? frame.midY - height / 2 : frame.maxY - height - 20
      window?.setFrameOrigin(NSPoint(x: max(frame.minX, x), y: max(frame.minY, y)))
    }
    // Order forward without activation: keyboard focus stays in the user's app.
    window?.orderFrontRegardless()
    expiration?.invalidate()
    expiration = Timer.scheduledTimer(withTimeInterval: 45, repeats: false) { [weak self] _ in
      MainActor.assumeIsolated { self?.finish(snooze: true) }
    }
  }
  func hide() { expiration?.invalidate(); expiration = nil; window?.orderOut(nil) }
  func finish(snooze: Bool) {
    guard window?.isVisible == true else { return }
    if !preview {
      if snooze { app.clock.snooze(kinds) } else { app.clock.complete(kinds) }
    }
    hide(); app.refreshStatus()
  }
}

/// What the system reports now. Notifications add away reasons; `HealthApp.tick` uses this only to
/// clear reasons the system no longer reports, so a missed unlock or wake cannot stop reminders.
struct HealthPresence: Equatable {
  var locked: Bool?, onConsole: Bool?
  var displayAsleep: Bool
  static func current() -> HealthPresence {
    let session = CGSessionCopyCurrentDictionary() as? [String: Any]
    return HealthPresence(locked: session.map { $0["CGSSessionScreenIsLocked"] as? Bool ?? false }, onConsole: session?["kCGSessionOnConsoleKey"] as? Bool,
      displayAsleep: CGDisplayIsAsleep(CGMainDisplayID()) != 0)
  }
  /// Unknown session state clears nothing; `sleep` clears only while the display is awake (not a dark wake).
  func stale(_ reasons: Set<String>) -> Set<String> {
    reasons.filter {
      switch $0 {
      case "lock": return locked == false
      case "session": return onConsole == true
      case "display", "sleep": return !displayAsleep
      default: return false
      }
    }
  }
}

@MainActor final class HealthApp: NSObject, NSApplicationDelegate, NSMenuDelegate {
  static let shared = HealthApp()
  static let bundleID = "com.productivity-os.health-breaks"
  /// A reason must be this old before `tick` may clear it, so a notification that arrives just before
  /// the session state (or the system sleeping) catches up is never undone.
  static let staleGrace: TimeInterval = 10
  var defaults = UserDefaults.standard
  var clock = BreakClock()
  var popup: HealthPopup?
  var settings: NSWindow?
  var statusItem: NSStatusItem?
  var timer: Timer?
  var reasons = Set<String>()
  private(set) var reasonSince: [String: TimeInterval] = [:]
  var presence: () -> HealthPresence = HealthPresence.current
  var uptime: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
  var observers: [(NotificationCenter, NSObjectProtocol)] = []
  var pauseUntil: Date?
  var receivedCommand = false
  var intervalFields: [BreakKind: NSTextField] = [:]
  var enabledRules: [BreakKind: NSButton] = [:]
  var enabledButton: NSButton?, centeredButton: NSButton?, soundButton: NSButton?, loginButton: NSButton?
  var idleField: NSTextField?, statusLabel: NSTextField?
  var settingsError: NSTextField?
  // Built once; menuNeedsUpdate relabels these items in place, so an open menu stays live.
  lazy var statusMenu = buildMenu()
  let stateMenuItem = NSMenuItem(), pauseMenuItem = NSMenuItem(), pomodoroMenuItem = NSMenuItem(), stalledMenuItem = NSMenuItem()
  let startPomodoroMenuItem = NSMenuItem(), postureMenuItem = NSMenuItem()
  private(set) var breakMenuItems: [BreakKind: NSMenuItem] = [:]
  private(set) var menuOpen = false
  lazy var pomodoro = PomodoroController(defaults: defaults, onChange: { [weak self] in self?.refreshPomodoroPresentation() })
  // Posture status changes only relabel; they never feed back into posture.update.
  lazy var posture = PostureCoach(defaults: defaults, onChange: { [weak self] in self?.refreshPostureStatus() })
  var idleSeconds: TimeInterval { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: UInt32.max)!) }
  /// Called only for input changes (tick, suspend, pause, launch, opening Posture Coach), never from presentation.
  func updatePosture() { posture.update(idleSeconds: idleSeconds, systemAllowed: reasons.isEmpty, monitoringAllowed: !paused) }
  func refreshPomodoroPresentation() {
    let title: String
    if let state = pomodoro.state {
      title = state.phase == .ready ? " Next Focus" : " \(state.title) \(pomodoro.countdown)\(state.paused || (state.phase == .focus && pomodoro.isAway) ? " Ⅱ" : "")"
    } else { title = "" }
    if let item = statusItem {
      let length = title.isEmpty ? NSStatusItem.squareLength : NSStatusItem.variableLength
      if item.length != length { item.length = length }
      // Redraw the menu bar only when the visible text changes.
      if item.button?.title != title { item.button?.title = title }
    }
    relabel(pomodoroMenuItem, pomodoro.summary)
    let stalled = pomodoro.state?.stalled == true
    relabel(stalledMenuItem, "Progress stopped · Raycast → Blocked Sites → End Stalled Round…", hidden: !stalled)
    let phase = pomodoro.state?.phase
    relabel(startPomodoroMenuItem, phase == .ready ? "Start Next Focus" : "Start Pomodoro", hidden: phase != nil && phase != .ready)
  }
  func refreshPostureStatus() { relabel(postureMenuItem, posture.status, hidden: !posture.isEnabled) }
  private func relabel(_ item: NSMenuItem, _ title: String, hidden: Bool = false) {
    if item.title != title { item.title = title }
    if item.isHidden != hidden { item.isHidden = hidden }
  }
  var loginURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/\(HealthApp.bundleID).plist")
  var paused: Bool { pauseUntil.map { $0 > Date() } ?? false }
  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.accessory)
    // terminate exits 0, so launchd's KeepAlive (SuccessfulExit = false) never respawns a duplicate.
    if NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).contains(where: { $0.processIdentifier != getpid() }) { NSApp.terminate(nil); return }
    loadPreferences()
    setupEditMenu()
    statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    statusItem?.button?.image = NSImage(systemSymbolName: "heart.circle", accessibilityDescription: "Health Breaks")
    statusItem?.button?.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
    statusItem?.menu = statusMenu
    installObservers()
    let current = presence(), launched = uptime()
    if current.locked == true { reasons.insert("lock"); reasonSince["lock"] = launched }
    if current.onConsole == false { reasons.insert("session"); reasonSince["session"] = launched }
    timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }
    timer?.tolerance = 1
    RunLoop.main.add(timer!, forMode: .common)
    pomodoro.startMonitoring(away: !reasons.isEmpty)
    updatePosture(); refreshStatus(); refreshPomodoroPresentation()
    if !receivedCommand && !CommandLine.arguments.contains("--background") { showSettings() }
  }
  func loadPreferences() {
    if let data = defaults.data(forKey: "preferences"), let prefs = try? JSONDecoder().decode(BreakPreferences.self, from: data) { clock.configure(prefs) }
    if let date = defaults.object(forKey: "pauseUntil") as? Date, date > Date() { pauseUntil = date }
  }
  func application(_ application: NSApplication, open urls: [URL]) {
    receivedCommand = true
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      for url in urls {
        guard url.scheme == "pos-health", url.query == nil, url.fragment == nil, url.user == nil, url.port == nil,
          url.path.isEmpty || url.path == "/" else { continue }
        switch url.host {
        case "settings": self.showSettings()
        case "break": self.showBreak()
        case "preview": self.showPreview()
        case "pomodoro": self.showPomodoro()
        case "pomodoro-start": self.pomodoro.startSilently()
        case "pomodoro-settings": self.showPomodoroSettings()
        case "posture": self.showPosture()
        case "quit-if-idle": self.quitIfIdle()
        default: break
        }
      }
    }
  }
  func setupEditMenu() {
    let main = NSMenu(), appItem = NSMenuItem(), appMenu = NSMenu()
    let quit = NSMenuItem(title: "Quit Health Breaks", action: #selector(quitApp), keyEquivalent: "q"); quit.target = self
    appMenu.addItem(quit); appItem.submenu = appMenu; main.addItem(appItem)
    let edit = NSMenuItem(title: "Edit", action: nil, keyEquivalent: ""), menu = NSMenu(title: "Edit")
    for (title, selector, key) in [("Cut", #selector(NSText.cut(_:)), "x"), ("Copy", #selector(NSText.copy(_:)), "c"), ("Paste", #selector(NSText.paste(_:)), "v"), ("Select All", #selector(NSText.selectAll(_:)), "a")] { menu.addItem(withTitle: title, action: selector, keyEquivalent: key) }
    edit.submenu = menu; main.addItem(edit); NSApp.mainMenu = main
  }
  func tick() {
    clearStaleReasons()
    let idle = idleSeconds
    let allowed = reasons.isEmpty && !paused
    let due = clock.sample(now: ProcessInfo.processInfo.systemUptime, idle: idle, allowed: allowed)
    if !allowed || idle >= clock.preferences.idleMinutes * 60 {
      if popup?.window?.isVisible == true { popup?.finish(snooze: true) }
    } else if !due.isEmpty {
      if popup == nil { popup = HealthPopup(app: self) }
      let combined = popup?.window?.isVisible == true && popup?.preview == false ? popup!.kinds.union(clock.pending) : clock.pending
      popup?.show(combined)
      if clock.preferences.sound { NSSound(named: "Glass")?.play() }
    }
    updatePosture(); refreshStatus()
  }
  func suspend(_ value: Bool, reason: String) {
    if value { if reasons.insert(reason).inserted { reasonSince[reason] = uptime() } } else { reasons.remove(reason); reasonSince[reason] = nil }
    clock.reanchor()
    if value { popup?.finish(snooze: true) }
    pomodoro.setAway(!reasons.isEmpty); updatePosture(); refreshStatus()
  }
  /// Notifications can be missed, which used to stop reminders and Pomodoro progress until the next
  /// lock cycle. Only removes reasons; adding one is left to the notifications themselves.
  func clearStaleReasons() {
    guard !reasons.isEmpty else { return }
    let now = uptime()
    for reason in presence().stale(reasons).sorted() where now - (reasonSince[reason] ?? -.infinity) >= Self.staleGrace { suspend(false, reason: reason) }
  }
  func installObservers() {
    let workspace = NSWorkspace.shared.notificationCenter
    for (name, reason, value) in [
      (NSWorkspace.willSleepNotification, "sleep", true), (NSWorkspace.didWakeNotification, "sleep", false),
      (NSWorkspace.sessionDidResignActiveNotification, "session", true), (NSWorkspace.sessionDidBecomeActiveNotification, "session", false),
      (NSWorkspace.screensDidSleepNotification, "display", true), (NSWorkspace.screensDidWakeNotification, "display", false)
    ] {
      let token = workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
        MainActor.assumeIsolated { self?.suspend(value, reason: reason) }
      }; observers.append((workspace, token))
    }
    let distributed = DistributedNotificationCenter.default()
    for (name, value) in [("com.apple.screenIsLocked", true), ("com.apple.screenIsUnlocked", false)] {
      let token = distributed.addObserver(forName: NSNotification.Name(name), object: nil, queue: .main) { [weak self] _ in
        MainActor.assumeIsolated { self?.suspend(value, reason: "lock") }
      }; observers.append((distributed, token))
    }
  }
  var reminderState: String {
    if !clock.preferences.enabled { return "Reminders off" }
    if paused { return "Paused until \(pauseUntil!.formatted(date: .omitted, time: .shortened))" }
    if !reasons.isEmpty { return "Paused while Mac is away" }
    return "\(Int(clock.activeSeconds / 60)) active minutes this session"
  }
  /// Cheap: relabels the settings window, the open menu (if any) and the tooltip; never rebuilds the menu.
  func refreshStatus() {
    let state = reminderState
    if let statusLabel, statusLabel.stringValue != state { statusLabel.stringValue = state }
    if menuOpen { populateMenu() }
    if let button = statusItem?.button, button.toolTip != "Health Breaks · " + state { button.toolTip = "Health Breaks · " + state }
  }
  func buildMenu() -> NSMenu {
    let menu = NSMenu(); menu.delegate = self
    menu.addItem(stateMenuItem)
    for kind in BreakKind.allCases { let item = NSMenuItem(); breakMenuItems[kind] = item; menu.addItem(item) }
    menu.addItem(.separator())
    func add(_ title: String, _ selector: Selector, _ item: NSMenuItem = NSMenuItem()) {
      item.title = title; item.action = selector; item.target = self; menu.addItem(item)
    }
    add("Take a Break Now", #selector(showBreak)); add("Preview Reminder", #selector(showPreview))
    add("Pause for One Hour", #selector(togglePause), pauseMenuItem)
    add("Settings…", #selector(showSettings)); menu.addItem(.separator())
    add("Pomodoro", #selector(showPomodoro), pomodoroMenuItem); menu.addItem(stalledMenuItem)
    add("Start Pomodoro", #selector(startPomodoro), startPomodoroMenuItem)
    add("Pomodoro Durations & Sites…", #selector(showPomodoroSettings))
    add("Posture Coach…", #selector(showPosture)); menu.addItem(postureMenuItem)
    menu.addItem(.separator()); add("Quit Health Breaks", #selector(quitApp))
    stalledMenuItem.isHidden = true; postureMenuItem.isHidden = true
    return menu
  }
  func populateMenu() {
    relabel(stateMenuItem, reminderState)
    for kind in BreakKind.allCases {
      guard let item = breakMenuItems[kind] else { continue }
      let enabled = clock.preferences.rules[kind.rawValue]?.enabled == true, remaining = clock.remaining(kind)
      relabel(item, "\(kind.title): \(remaining <= 0 ? "due" : "in \(Int(ceil(remaining / 60))) active min")", hidden: !enabled)
    }
    relabel(pauseMenuItem, paused ? "Resume Reminders" : "Pause for One Hour")
    refreshPomodoroPresentation(); refreshPostureStatus()
  }
  func menuNeedsUpdate(_ menu: NSMenu) { populateMenu() }
  func menuWillOpen(_ menu: NSMenu) { menuOpen = true; pomodoro.retry() }
  func menuDidClose(_ menu: NSMenu) { menuOpen = false }
  @objc func showPomodoro() { pomodoro.showControls(); pomodoro.retry() }
  @objc func startPomodoro() { pomodoro.startSilently() }
  @objc func showPomodoroSettings() { pomodoro.showSettings() }
  @objc func showPosture() { updatePosture(); posture.showSettings() }
  @objc func togglePause() {
    pauseUntil = paused ? nil : Date().addingTimeInterval(3600)
    defaults.set(pauseUntil, forKey: "pauseUntil")
    clock.reanchor(); popup?.finish(snooze: true); updatePosture(); refreshStatus()
  }
  @objc func showBreak() {
    guard reasons.isEmpty else { return }
    if popup == nil { popup = HealthPopup(app: self) }
    popup?.show(Set(BreakKind.allCases))
  }
  @objc func showPreview() {
    guard reasons.isEmpty else { return }
    if popup == nil { popup = HealthPopup(app: self) }
    if popup?.window?.isVisible == true && popup?.preview == false { popup?.finish(snooze: true) }
    popup?.show(Set(BreakKind.allCases), preview: true)
  }
  @objc func quitApp() { NSApp.terminate(nil) }
  /// No open window, menu or posture calibration that a restart would interrupt. Reminder popups and Pomodoro
  /// notices are transient; an unfinished round pauses safely and resumes after the restart.
  var idleForQuit: Bool {
    !menuOpen && !posture.isBusy && [settings, pomodoro.window, pomodoro.settings].allSatisfy { $0?.isVisible != true }
  }
  /// Installer request (`pos-health://quit-if-idle`): exits 0 when idle, so launchd's KeepAlive stays out of
  /// it; otherwise does nothing and the update waits. Never shows UI or activates the app.
  func quitIfIdle() { if idleForQuit { NSApp.terminate(nil) } }
  func applicationWillTerminate(_ notification: Notification) {
    timer?.invalidate(); popup?.hide(); pomodoro.shutdown(); posture.shutdown()
    for (center, token) in observers { center.removeObserver(token) }
  }
  @objc func showSettings() {
    if settings == nil {
      let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 490, height: 565), styleMask: [.titled, .closable], backing: .buffered, defer: false)
      window.title = "Health Breaks"; window.isReleasedWhenClosed = false
      let root = HealthSettingsBackground(frame: window.contentView!.bounds)
      window.contentView = root
      func label(_ title: String, x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat = 22, small: Bool = false) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: title); field.frame = NSRect(x: x, y: y, width: width, height: height)
        field.font = .systemFont(ofSize: small ? 11 : 13); root.addSubview(field); return field
      }
      let pomodoroButton = HealthButton("Pomodoro…") { [weak self] in self?.showPomodoro() }
      pomodoroButton.frame = NSRect(x: 20, y: 517, width: 215, height: 30); root.addSubview(pomodoroButton)
      let postureButton = HealthButton("Posture Coach…") { [weak self] in self?.showPosture() }
      postureButton.frame = NSRect(x: 250, y: 517, width: 220, height: 30); root.addSubview(postureButton)
      statusLabel = label("", x: 20, y: 470, width: 450)
      statusLabel?.font = .systemFont(ofSize: 15, weight: .semibold)
      let enabled = NSButton(checkboxWithTitle: "Enable health reminders", target: nil, action: nil)
      enabled.frame = NSRect(x: 20, y: 432, width: 450, height: 25); root.addSubview(enabled); enabledButton = enabled
      _ = label("Remind me after this many active minutes:", x: 20, y: 402, width: 450)
      for (index, kind) in BreakKind.allCases.enumerated() {
        let y = CGFloat(365 - index * 36)
        let button = NSButton(checkboxWithTitle: kind.title, target: nil, action: nil)
        button.frame = NSRect(x: 20, y: y, width: 260, height: 25); root.addSubview(button); enabledRules[kind] = button
        let field = NSTextField(string: ""); field.frame = NSRect(x: 315, y: y, width: 70, height: 24)
        field.setAccessibilityLabel("\(kind.title) interval in minutes")
        root.addSubview(field); intervalFields[kind] = field
        _ = label("min", x: 396, y: y, width: 60)
      }
      _ = label("Pause counting after no input for", x: 20, y: 250, width: 285)
      let idle = NSTextField(string: "2"); idle.frame = NSRect(x: 315, y: 250, width: 70, height: 24)
      idle.setAccessibilityLabel("Idle threshold in minutes"); root.addSubview(idle); idleField = idle
      _ = label("min", x: 396, y: 250, width: 60)
      let info = label("No input means no keyboard, mouse, or trackpad activity. Reading without input may pause counting. Sleep and lock never count. Timers restart when the helper restarts.", x: 20, y: 195, width: 450, height: 48, small: true)
      info.textColor = .secondaryLabelColor
      let centered = NSButton(checkboxWithTitle: "Show popup in the center of the screen", target: nil, action: nil)
      centered.frame = NSRect(x: 20, y: 166, width: 450, height: 25); root.addSubview(centered); centeredButton = centered
      let sound = NSButton(checkboxWithTitle: "Play a gentle sound", target: nil, action: nil)
      sound.frame = NSRect(x: 20, y: 137, width: 450, height: 25); root.addSubview(sound); soundButton = sound
      let login = NSButton(checkboxWithTitle: "Start Health Breaks at login", target: nil, action: nil)
      login.frame = NSRect(x: 20, y: 108, width: 450, height: 25); root.addSubview(login); loginButton = login
      settingsError = label("", x: 20, y: 70, width: 450, height: 32, small: true); settingsError?.textColor = .systemRed
      let preview = HealthButton("Preview Popup") { [weak self] in self?.showPreview() }
      preview.frame = NSRect(x: 20, y: 20, width: 140, height: 32); root.addSubview(preview)
      let reset = HealthButton("Reset Timers") { [weak self] in
        guard let self else { return }; self.popup?.hide(); self.clock.complete(Set(BreakKind.allCases)); self.clock.reanchor(); self.refreshStatus()
      }
      reset.frame = NSRect(x: 173, y: 20, width: 140, height: 32); root.addSubview(reset)
      let save = HealthButton("Save Settings") { [weak self] in self?.saveSettings() }
      save.frame = NSRect(x: 326, y: 20, width: 144, height: 32); root.addSubview(save)
      settings = window
    }
    let prefs = clock.preferences
    enabledButton?.state = prefs.enabled ? .on : .off
    centeredButton?.state = prefs.centered ? .on : .off
    soundButton?.state = prefs.sound ? .on : .off
    loginButton?.state = FileManager.default.fileExists(atPath: loginURL.path) ? .on : .off
    idleField?.stringValue = String(format: "%g", prefs.idleMinutes)
    for kind in BreakKind.allCases {
      enabledRules[kind]?.state = prefs.rules[kind.rawValue]?.enabled == true ? .on : .off
      intervalFields[kind]?.stringValue = String(format: "%g", prefs.rules[kind.rawValue]?.minutes ?? kind.defaultMinutes)
    }
    settingsError?.stringValue = ""; refreshStatus()
    settings?.center(); settings?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
  }
  func saveSettings() {
    settingsError?.textColor = .systemRed
    var value = clock.preferences
    for kind in BreakKind.allCases {
      guard let raw = intervalFields[kind]?.stringValue, let minutes = Double(raw), minutes.isFinite, (1...240).contains(minutes) else {
        settingsError?.stringValue = "Enter reminder intervals between 1 and 240 minutes."; return
      }
      value.rules[kind.rawValue] = BreakRule(enabled: enabledRules[kind]?.state == .on, minutes: minutes)
    }
    guard let raw = idleField?.stringValue, let idle = Double(raw), idle.isFinite, (1...15).contains(idle) else {
      settingsError?.stringValue = "Enter an idle threshold between 1 and 15 minutes."; return
    }
    value.idleMinutes = idle; value.enabled = enabledButton?.state == .on
    value.centered = centeredButton?.state == .on; value.sound = soundButton?.state == .on
    do {
      try configureLogin(loginButton?.state == .on)
      defaults.set(try JSONEncoder().encode(value), forKey: "preferences")
      popup?.finish(snooze: true); clock.configure(value)
      settingsError?.textColor = .secondaryLabelColor
      settingsError?.stringValue = "Settings saved"; refreshStatus()
    } catch { settingsError?.stringValue = "Could not save: \(error.localizedDescription)" }
  }
  /// The shared helper LaunchAgent: launchd restarts a crash (non-zero exit or signal) after 30 s,
  /// while a deliberate Quit or duplicate-instance exit (status 0) stays stopped.
  static func loginPlist(executable: String) -> [String: Any] {
    ["Label": bundleID, "ProgramArguments": [executable, "--background"], "RunAtLoad": true, "KeepAlive": ["SuccessfulExit": false],
     "ProcessType": "Interactive", "ThrottleInterval": 30, "LimitLoadToSessionType": "Aqua"]
  }
  /// Writes or deletes the file only: bootstrapping or booting out from inside the app could stop it.
  func configureLogin(_ enabled: Bool) throws {
    let fm = FileManager.default
    if enabled {
      guard let executable = Bundle.main.executablePath else { return }
      try fm.createDirectory(at: loginURL.deletingLastPathComponent(), withIntermediateDirectories: true)
      try PropertyListSerialization.data(fromPropertyList: Self.loginPlist(executable: executable), format: .xml, options: 0).write(to: loginURL, options: .atomic)
    } else if fm.fileExists(atPath: loginURL.path) { try fm.removeItem(at: loginURL) }
  }
}
