import AppKit
import CoreGraphics

var passed = 0
func check(_ condition: @autoclosure () throws -> Bool, _ message: String) {
  guard (try? condition()) == true else { print("FAIL: \(message)"); exit(1) }
  passed += 1; print("PASS: \(message)")
}
@main struct HealthTests {
  @MainActor static func main() {
    let app = NSApplication.shared; app.setActivationPolicy(.accessory)
    Task { @MainActor in
      do { try await run(); exit(0) } catch { print("FAIL: \(error)"); exit(1) }
    }
    app.run()
  }
  @MainActor static func run() async throws {
    setbuf(stdout, nil)
    let root = URL(fileURLWithPath: CommandLine.arguments[1])
    func shortClock() -> BreakClock {
      var prefs = BreakPreferences()
      for kind in BreakKind.allCases { prefs.rules[kind.rawValue] = BreakRule(minutes: 1) }
      var c = BreakClock(); c.configure(prefs); return c
    }
    func work(_ clock: inout BreakClock, from: Int, through: Int, allowed: Bool = true) -> Set<BreakKind> {
      var due = Set<BreakKind>()
      for time in stride(from: from, through: through, by: 5) { due.formUnion(clock.sample(now: Double(time), idle: 0, allowed: allowed)) }
      return due
    }
    let defaults = BreakPreferences()
    check(defaults.rules["eyes"]?.minutes == 20 && defaults.rules["stretch"]?.minutes == 45 && defaults.rules["water"]?.minutes == 60, "User's 20/45/60-minute defaults")
    check(!defaults.centered && !defaults.sound, "Small quiet popup is the default")
    var c = shortClock()
    check(work(&c, from: 0, through: 55).isEmpty, "Reminders never fire before the active-time threshold")
    check(c.sample(now: 60, idle: 0, allowed: true) == Set(BreakKind.allCases), "Reminders due together form one batch")
    check(c.sample(now: 65, idle: 0, allowed: true).isEmpty, "Pending reminders are not repeatedly emitted")
    c.complete([.eyes])
    check(c.remaining(.eyes) == 60 && c.pending == [.stretch, .water], "Done resets only the displayed reminder types")
    c.snooze([.stretch, .water], seconds: 10)
    check(c.pending.isEmpty, "Snooze clears pending reminders")
    check(c.sample(now: 70, idle: 0, allowed: true).isEmpty, "Snooze waits its full active interval")
    check(c.sample(now: 75, idle: 0, allowed: true) == [.stretch, .water], "Snoozed types return when due")
    check(c.remaining(.eyes) == 50, "Unrelated reminder keeps progressing during snooze")
    c = shortClock(); _ = work(&c, from: 0, through: 30)
    _ = work(&c, from: 35, through: 600, allowed: false)
    check(c.activeSeconds == 30 && c.remaining(.eyes) == 30, "Paused time never advances reminders")
    check(c.sample(now: 605, idle: 0, allowed: true).isEmpty && c.activeSeconds == 30, "Resuming never credits the last paused interval")
    _ = c.sample(now: 610, idle: 0, allowed: true)
    check(c.activeSeconds == 35, "Active time resumes after the new baseline")
    c.reanchor(); _ = c.sample(now: 36000, idle: 0, allowed: true)
    check(c.activeSeconds == 35, "Sleep/wake reanchoring never adds sleeping time")
    _ = c.sample(now: 37000, idle: 0, allowed: true)
    check(c.activeSeconds == 35, "Long timer stalls are not counted as work")
    _ = c.sample(now: 2, idle: 0, allowed: true)
    check(c.activeSeconds == 35, "Backwards monotonic time cannot create work")
    _ = c.sample(now: .nan, idle: 0, allowed: true)
    check(c.activeSeconds == 35, "Invalid samples cannot corrupt active counters")
    c = BreakClock()
    _ = c.sample(now: 0, idle: 0, allowed: true)
    for time in stride(from: 5, through: 600, by: 5) { _ = c.sample(now: Double(time), idle: Double(time), allowed: true) }
    check(c.activeSeconds == 120, "Idle detection stops counting after the two-minute grace period")
    _ = c.sample(now: 605, idle: 1, allowed: true)
    check(c.activeSeconds == 121, "Returning from idle credits only the observed recent input interval")
    _ = c.sample(now: 610, idle: 0, allowed: true)
    check(c.activeSeconds == 126, "Fresh input resumes normal accounting")
    c = shortClock(); _ = work(&c, from: 0, through: 60); c.snooze(Set(BreakKind.allCases))
    c.reanchor(); _ = c.sample(now: 1000, idle: 1000, allowed: true)
    _ = c.sample(now: 1005, idle: 1005, allowed: true)
    check(c.remaining(.eyes) == 300, "Snooze freezes while idle")
    var prefs = BreakPreferences()
    prefs.idleMinutes = .infinity; prefs.rules["eyes"] = BreakRule(minutes: -1); prefs.rules["stretch"] = BreakRule(minutes: 9999)
    let validated = prefs.validated()
    check(validated.idleMinutes == 2 && validated.rules["eyes"]?.minutes == 1 && validated.rules["stretch"]?.minutes == 240, "Invalid stored intervals are normalized safely")
    c = shortClock(); _ = work(&c, from: 0, through: 60)
    var disabled = c.preferences; disabled.rules["eyes"]?.enabled = false; c.configure(disabled)
    check(!c.pending.contains(.eyes) && c.elapsed[.eyes] == 0, "Disabling a reminder clears its pending state")
    disabled.enabled = false; c.configure(disabled)
    _ = work(&c, from: 65, through: 600)
    check(c.pending.isEmpty && c.activeSeconds == 60, "Master off suppresses reminders and counting")
    c = BreakClock(); var dueAt: [BreakKind: Int] = [:]
    for time in stride(from: 0, through: 3600, by: 5) {
      for kind in c.sample(now: Double(time), idle: 0, allowed: true) { dueAt[kind] = time }
    }
    check(dueAt == [.eyes: 1200, .stretch: 2700, .water: 3600], "Actual default schedule fires at 20, 45, and 60 active minutes")
    var longRun = shortClock(), reminders = 0
    for time in stride(from: 0, through: 86400 * 7, by: 5) {
      let due = longRun.sample(now: Double(time), idle: 0, allowed: true)
      if !due.isEmpty { reminders += due.count; longRun.complete(due) }
    }
    check(reminders == 7 * 24 * 60 * 3, "Seven simulated days preserve exact reminder cadence without drift")
    check(longRun.elapsed.count == 3 && longRun.snoozed.isEmpty && longRun.pending.isEmpty, "Scheduler storage stays bounded over long sessions")

    let app = HealthApp(), suite = "health-breaks-qa-\(UUID().uuidString)"
    app.defaults = UserDefaults(suiteName: suite)!
    // Never touch the real LaunchAgent from tests.
    app.loginURL = root.appendingPathComponent("LaunchAgents/\(HealthApp.bundleID).plist")
    defer { app.defaults.removePersistentDomain(forName: suite) }
    app.clock = shortClock(); _ = work(&app.clock, from: 0, through: 60)
    app.showSettings()
    let initialEyesInterval = app.intervalFields[.eyes]?.stringValue
    check(initialEyesInterval == "1", "Settings reflect the configured timer (actual: \(String(describing: initialEyesInterval)))")
    try await Task.sleep(nanoseconds: 200_000_000)
    check(app.settings?.isVisible == true, "Settings window opens")
    app.intervalFields[.eyes]?.stringValue = "bad input"
    let before = app.clock.preferences
    app.saveSettings()
    check(app.clock.preferences == before && app.settingsError?.stringValue.isEmpty == false, "Invalid settings do not mutate preferences or startup configuration")
    if let view = app.settings?.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
      view.cacheDisplay(in: view.bounds, to: rep)
      try rep.representation(using: .png, properties: [:])?.write(to: root.appendingPathComponent("settings.png"))
    }
    let snapshot = app.clock
    app.showPreview()
    check(app.popup?.window?.isVisible == true && app.popup?.preview == true, "Preview shows the reminder popup")
    check(app.settings?.isKeyWindow == true && app.popup?.window?.isKeyWindow == false, "Reminder popup does not take keyboard focus")
    check(app.popup?.window?.isOpaque == false, "Popup uses a translucent native panel")
    if let view = app.popup?.window?.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
      view.cacheDisplay(in: view.bounds, to: rep)
      try rep.representation(using: .png, properties: [:])?.write(to: root.appendingPathComponent("popup.png"))
    }
    app.popup?.finish(snooze: false)
    check(app.clock.elapsed == snapshot.elapsed && app.clock.pending == snapshot.pending, "Closing a preview never completes real reminders")
    app.showBreak(); app.popup?.finish(snooze: false)
    check(app.clock.pending.isEmpty && app.clock.remaining(.eyes) == 60, "Done completes an actual break")
    app.suspend(true, reason: "lock")
    check(app.clock.snoozed.isEmpty, "Locking after Done cannot snooze already-completed reminders")
    app.suspend(true, reason: "sleep"); app.suspend(false, reason: "lock")
    check(!app.reasons.isEmpty, "Unlock does not resume while another suspension remains")
    app.showBreak()
    check(app.popup?.window?.isVisible == false, "Manual reminders cannot appear during lock or sleep")
    app.suspend(false, reason: "sleep"); app.showBreak(); app.popup?.finish(snooze: true)
    check(app.clock.remaining(.eyes) == 300, "Popup Snooze postpones displayed types by five active minutes")
    app.showBreak(); app.suspend(true, reason: "lock")
    check(app.popup?.window?.isVisible == false && app.clock.remaining(.water) == 300, "Lock hides a visible reminder and avoids a reminder flood on return")
    app.suspend(false, reason: "lock")
    var presence = HealthPresence(locked: true, onConsole: false, displayAsleep: true), fakeUptime: TimeInterval = 1000
    app.presence = { presence }; app.uptime = { fakeUptime }
    for reason in ["lock", "session", "display", "sleep"] { app.suspend(true, reason: reason) }
    fakeUptime += 60; app.clearStaleReasons()
    check(app.reasons == ["lock", "session", "display", "sleep"] && app.pomodoro.isAway, "Reasons the system still reports are never cleared by the periodic check")
    presence = HealthPresence(locked: false, onConsole: true, displayAsleep: true); app.clearStaleReasons()
    check(app.reasons == ["display", "sleep"], "A missed unlock or session return clears its stale reason, while sleep waits for the display to wake")
    presence.displayAsleep = false; app.suspend(true, reason: "lock"); presence.locked = false; app.clearStaleReasons()
    check(app.reasons == ["lock"], "Display and sleep clear once the display is awake, while a just-added reason waits out its grace period")
    fakeUptime += HealthApp.staleGrace; app.clearStaleReasons()
    check(app.reasons.isEmpty && !app.pomodoro.isAway, "Stale reasons clear through suspend, so reminders and Pomodoro resume after a missed notification")
    check(HealthPresence(locked: nil, onConsole: nil, displayAsleep: true).stale(["lock", "session", "display", "sleep", "other"]).isEmpty,
      "Unknown session state never clears a reason")
    app.presence = HealthPresence.current; app.uptime = { ProcessInfo.processInfo.systemUptime }
    app.togglePause(); check(app.paused, "One-hour pause enables")
    app.togglePause(); check(!app.paused, "Resume clears a manual pause")
    let menu = app.statusMenu, pomodoroItem = app.pomodoroMenuItem, itemCount = menu.items.count
    app.togglePause(); app.menuNeedsUpdate(menu); let pausedTitle = app.pauseMenuItem.title
    app.togglePause(); app.refreshStatus(); app.refreshPomodoroPresentation(); app.menuNeedsUpdate(menu)
    check(app.statusMenu === menu && app.pomodoroMenuItem === pomodoroItem && menu.items.count == itemCount && menu.items.contains(pomodoroItem)
      && (menu.delegate as AnyObject?) === app && pausedTitle == "Resume Reminders" && app.pauseMenuItem.title == "Pause for One Hour"
      && pomodoroItem.title == app.pomodoro.summary && app.breakMenuItems[.eyes]?.title.hasPrefix("Rest your eyes: ") == true,
      "The status menu is built once and relabelled in place across refreshes")
    let encoded = try JSONEncoder().encode(BreakPreferences())
    app.defaults.set(encoded, forKey: "preferences"); app.loadPreferences()
    check(app.clock.preferences == BreakPreferences(), "Preferences survive reload")
    let executable = "/Applications/Health Breaks.app/Contents/MacOS/HealthBreaks", plist = HealthApp.loginPlist(executable: executable)
    check(plist.count == 7 && plist["Label"] as? String == HealthApp.bundleID && plist["ProgramArguments"] as? [String] == [executable, "--background"]
      && plist["RunAtLoad"] as? Bool == true && plist["KeepAlive"] as? [String: Bool] == ["SuccessfulExit": false] && plist["ProcessType"] as? String == "Interactive"
      && plist["ThrottleInterval"] as? Int == 30 && plist["LimitLoadToSessionType"] as? String == "Aqua",
      "Start at login uses the shared LaunchAgent contract: crashes restart, deliberate exits do not")
    try app.configureLogin(true)
    let written = try PropertyListSerialization.propertyList(from: Data(contentsOf: app.loginURL), format: nil) as? [String: Any]
    check(written?["KeepAlive"] as? [String: Bool] == ["SuccessfulExit": false] && written?["ThrottleInterval"] as? Int == 30
      && (written?["ProgramArguments"] as? [String])?.last == "--background", "Turning start at login on writes the LaunchAgent plist")
    try app.configureLogin(false)
    check(!FileManager.default.fileExists(atPath: app.loginURL.path), "Turning start at login off only deletes the plist")
    check(!app.idleForQuit, "An installer quit-if-idle request waits while a settings window is open")
    app.popup?.hide(); app.settings?.close()
    check(app.idleForQuit, "With no window, menu or calibration open, quit-if-idle may restart Health Breaks")
    let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: UInt32.max)!)
    check(idle.isFinite && idle >= 0, "Live input-idle API returns a usable duration without input capture")
    try await runPomodoroTests(root: root)
    try await runPostureLifecycleTests(root: root)
    app.pomodoro.shutdown(); app.posture.shutdown()
    try Data("complete".utf8).write(to: root.appendingPathComponent("qa-complete"))
    print("Health Breaks native QA: \(passed) checks passed")
  }
}
