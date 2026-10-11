import AppKit

/// A short status line that can never become key, so a silent start cannot take keyboard focus.
@MainActor final class PomodoroConfirmationPanel: NSPanel {
  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }
}

@MainActor final class PomodoroController {
  let defaults: UserDefaults
  let client: PomodoroClient
  let monitorID: String
  let domainProvider: ([String]) throws -> [String]
  let uptime: () -> TimeInterval
  let now: () -> Date
  let recoverySchedule: (Int) -> TimeInterval
  let onChange: () -> Void
  var preferences: PomodoroPreferences
  private(set) var display = PomodoroDisplayClock()
  private(set) var error: String?
  private(set) var pending = 0
  private(set) var monitoring = false
  private(set) var isAway = false
  private(set) var lastCheck: TimeInterval = -.infinity
  private(set) var recoveryAttempt = 0
  /// Delay of the pending stuck-pause/error retry, if one is scheduled.
  private(set) var scheduledRecovery: TimeInterval?
  private var operation: Task<Void, Never>?
  private var displayTimer: Timer?
  private var pollTimer: Timer?
  private var breakTimer: Timer?
  private var recoveryTimer: Timer?
  private var pollInterval: TimeInterval?
  private var activity: NSObjectProtocol?
  private var stopped = false
  var window: NSWindow?
  var settings: NSWindow?
  var notice: NSPanel?
  private(set) var confirmation: NSPanel?
  private(set) var confirmationText: (title: String, detail: String)?
  private var noticeTimer: Timer?, confirmationTimer: Timer?
  private var pendingReadyNotice = false
  private var titleField: NSTextField?, detailField: NSTextField?, errorField: NSTextField?
  private var primaryButton: HealthButton?, stopButton: HealthButton?
  var settingFields: [NSTextField] = []
  var presetButtons: [String: NSButton] = [:]
  private var timersEnabled = true
  var settingsError: NSTextField?
  var state: PomodoroState? { display.state }
  var busy: Bool { pending > 0 }
  /// Paused as away/monitor while this Mac is present: the helper's probe raced an unlock or was
  /// briefly unavailable. Retried on `recoverySchedule` instead of waiting for a manual Resume.
  var needsRecovery: Bool { state?.phase == .focus && state?.paused == true && (state?.pauseReason == "away" || state?.pauseReason == "monitor") && !isAway }
  /// Held while focus runs or recovers: App Nap would stretch checkpoints past the helper's 15 s lease.
  var holdsActivity: Bool { activity != nil }
  var focusRunning: Bool { monitoring && display.focusRunning && error == nil }
  var remaining: TimeInterval { display.remaining(uptime: uptime(), date: now()) }
  var countdown: String { let seconds = Int(ceil(remaining)); return String(format: "%02d:%02d", seconds / 60, seconds % 60) }
  var summary: String {
    guard let state else { return error == nil ? "Pomodoro" : "Pomodoro · Connection needed" }
    if state.phase == .ready { return "Pomodoro · Ready for next focus" }
    if error != nil { return "\(state.title) \(countdown) · Reconnecting" }
    let suffix = state.stalled == true ? " · Stalled" : state.paused || (state.phase == .focus && isAway) ? " · Paused" : ""
    return "\(state.title) \(countdown)\(suffix)"
  }
  var stalledNote: String? {
    state?.stalled == true ? "Progress has stopped. If it does not resume, end the round in Raycast → Blocked Sites → “End Stalled Round…”. Site blocks stay." : nil
  }
  init(defaults: UserDefaults = .standard, client: PomodoroClient = PomodoroClient(), monitorID: String = UUID().uuidString,
       domainProvider: @escaping ([String]) throws -> [String] = { try PomodoroPresets.bundled(selected: $0) },
       uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }, now: @escaping () -> Date = Date.init,
       recoverySchedule: @escaping (Int) -> TimeInterval = PomodoroRecovery.delay(after:), onChange: @escaping () -> Void = {}) {
    self.defaults = defaults; self.client = client; self.monitorID = monitorID; self.domainProvider = domainProvider
    self.uptime = uptime; self.now = now; self.recoverySchedule = recoverySchedule; self.onChange = onChange
    preferences = PomodoroPreferences.load(defaults)
  }
  func startMonitoring(away: Bool = false, timers: Bool = true) {
    guard !monitoring else { return }; monitoring = true; stopped = false; timersEnabled = timers; isAway = away; display.away = away
    enqueue { controller in
      let value = try await controller.client.request(["pomodoro-status"])
      controller.accept(value)
      if value?.phase == .focus {
        let command = controller.isAway ? ["pomodoro-pause", controller.monitorID, "away"] : ["pomodoro-checkpoint", controller.monitorID]
        controller.accept(try await controller.client.request(command))
      }
    }
  }
  /// Called on lock/sleep immediately; focus remains frozen until the helper confirms resumption.
  func setAway(_ away: Bool) {
    guard isAway != away else { return }
    if away, var current = state, current.phase == .focus, !current.paused {
      current.remainingMs = remaining * 1000; current.paused = true; current.pauseReason = "away"; display.accept(current, uptime: uptime())
    }
    isAway = away; display.away = away
    if away { hideNotice(); hideConfirmation() }
    updatePresentation()
    guard monitoring else { return }
    enqueue { controller in
      // Re-evaluate at execution time so an earlier status request cannot hide a running focus.
      if controller.state?.phase == .focus {
        let command = away ? ["pomodoro-pause", controller.monitorID, "away"] : ["pomodoro-checkpoint", controller.monitorID]
        controller.accept(try await controller.client.request(command))
      } else if !away { controller.accept(try await controller.client.request(["pomodoro-status"])) }
    }
  }
  func poll(force: Bool = false) {
    guard monitoring, !busy, !stopped else { return }
    let running = state?.phase == .focus && state?.paused == false && !isAway
    guard force || running || needsRecovery || error != nil else { return }
    enqueue { controller in
      let command = controller.state?.phase == .focus && controller.state?.pauseReason != "manual" && !controller.isAway ? ["pomodoro-checkpoint", controller.monitorID] : ["pomodoro-status"]
      controller.accept(try await controller.client.request(command))
    }
  }
  func tick() {
    updatePresentation()
    // Reconcile a completed break promptly; never start the next focus automatically.
    if state?.isBreak == true, remaining <= 0, !busy, uptime() - lastCheck >= 1 { poll(force: true) }
  }
  func startOrShow() {
    showControls()
    enqueue { controller in
      let current = try await controller.client.request(["pomodoro-status"])
      controller.accept(current)
      guard current == nil else { return }
      guard !controller.isAway else { throw PomodoroError.unavailable("Unlock your Mac before starting focus.") }
      let domains = try controller.domainProvider(controller.preferences.presetNames)
      guard !domains.isEmpty else { throw PomodoroError.missingPresets }
      controller.accept(try await controller.client.request(["start-pomodoro"] + controller.preferences.arguments + ["Pomodoro"] + domains))
      controller.accept(try await controller.client.request(["pomodoro-checkpoint", controller.monitorID]))
    }
  }
  /// `pos-health://pomodoro-start`: never opens a window or activates the app. Starts a plan, or the
  /// next focus when one is ready; a running round only reports its status. Errors open the controls.
  func startSilently() {
    hideConfirmation()
    enqueue({ controller in
      let current = try await controller.client.request(["pomodoro-status"])
      controller.accept(current)
      guard current == nil || current?.phase == .ready else { controller.showConfirmation(started: false); return }
      guard !controller.isAway else { throw PomodoroError.unavailable("Unlock your Mac before starting focus.") }
      if current == nil {
        let domains = try controller.domainProvider(controller.preferences.presetNames)
        guard !domains.isEmpty else { throw PomodoroError.missingPresets }
        controller.accept(try await controller.client.request(["start-pomodoro"] + controller.preferences.arguments + ["Pomodoro"] + domains))
        controller.accept(try await controller.client.request(["pomodoro-checkpoint", controller.monitorID]))
      } else { controller.accept(try await controller.client.request(["pomodoro-next", controller.monitorID] + controller.preferences.arguments)) }
      controller.showConfirmation(started: true)
    }, onError: { $0.showControls() })
  }
  /// Plans store expanded domains, so name the preset groups they fully contain.
  func blockedGroups(_ state: PomodoroState) -> String {
    let domains = Set(state.domains)
    let groups = ["social", "news", "video"].filter { name in (try? domainProvider([name])).map { !$0.isEmpty && Set($0).isSubset(of: domains) } ?? false }
    let sites = state.domains.filter { !$0.hasPrefix("www.") }.count
    return groups.isEmpty ? "Blocking \(sites) site\(sites == 1 ? "" : "s")" : "Blocking " + groups.map(\.capitalized).joined(separator: " + ")
  }
  func primaryAction() {
    guard !busy else { return }
    guard let state else { startOrShow(); return }
    if state.phase == .ready {
      enqueue { controller in
        guard !controller.isAway else { return }
        controller.accept(try await controller.client.request(["pomodoro-next", controller.monitorID] + controller.preferences.arguments))
      }
    } else if state.phase == .focus {
      let command = state.paused ? ["pomodoro-resume", monitorID] : ["pomodoro-pause", monitorID, "manual"]
      enqueue { controller in
        guard !controller.isAway else { return }
        controller.accept(try await controller.client.request(command))
      }
    }
  }
  func stopFutureCycles() {
    guard !busy, let state, state.phase != .focus else { return }
    enqueue { controller in controller.accept(try await controller.client.request(["pomodoro-stop"])) }
  }
  func retry() { poll(force: true) }
  func shutdown() {
    stopped = true; monitoring = false
    displayTimer?.invalidate(); displayTimer = nil; pollTimer?.invalidate(); pollTimer = nil
    recoveryTimer?.invalidate(); recoveryTimer = nil; scheduledRecovery = nil
    hideNotice(); hideConfirmation(); pendingReadyNotice = false
    breakTimer?.invalidate(); breakTimer = nil; pollInterval = nil
    configureActivity()
    // The root helper expires the monitor lease if the app exits mid-focus.
    operation?.cancel()
  }
  func waitForIdle() async { await operation?.value }
  private func enqueue(_ work: @escaping @MainActor (PomodoroController) async throws -> Void, onError: (@MainActor (PomodoroController) -> Void)? = nil) {
    guard !stopped else { return }
    let previous = operation; pending += 1; updatePresentation()
    operation = Task { @MainActor [weak self] in
      await previous?.value
      guard let self else { return }
      defer { self.pending -= 1; self.updatePresentation() }
      guard !Task.isCancelled, !self.stopped else { return }
      do { try await work(self); self.error = nil }
      catch { self.error = error.localizedDescription; onError?(self) }
    }
  }
  private func accept(_ value: PomodoroState?) {
    guard !stopped else { return }
    let previous = state
    lastCheck = uptime(); display.accept(value, uptime: lastCheck); display.away = isAway
    if value?.phase != .ready { pendingReadyNotice = false }
    if previous?.isBreak == true && value?.phase == .ready { pendingReadyNotice = true }
    if let value, previous?.phase == .focus && value.isBreak && !isAway { showNotice(value) }
    if let value, value.phase == .ready && pendingReadyNotice && !isAway {
      pendingReadyNotice = false; showNotice(value)
    }
    if value == nil || value?.phase == .focus { hideNotice() }
    breakTimer?.invalidate(); breakTimer = nil
    // Every reply re-bases the estimate: re-align the display ticks to its second boundaries.
    displayTimer?.invalidate(); displayTimer = nil
    updatePresentation()
  }
  private func configureTimers() {
    let live = monitoring && timersEnabled && !stopped
    let running = state?.phase == .focus && state?.paused == false && !isAway
    let liveBreak = state?.isBreak == true && state?.paused == false
    let visibleCountdown = live && !isAway && error == nil && (running || (liveBreak && remaining > 0))
    if visibleCountdown && displayTimer == nil {
      // Fire just after each displayed second changes, not at an arbitrary phase of it.
      let timer = Timer(fire: Date(timeIntervalSinceNow: PomodoroDisplayClock.tickDelay(remaining: remaining)), interval: 1, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }
      timer.tolerance = 0.05; RunLoop.main.add(timer, forMode: .common); displayTimer = timer
    } else if !visibleCountdown { displayTimer?.invalidate(); displayTimer = nil }
    let interval: TimeInterval? = live && running && error == nil ? 10 : nil
    if interval != pollInterval {
      pollTimer?.invalidate(); pollTimer = nil; pollInterval = interval
      if let interval {
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.poll() } }
        timer.tolerance = 1; RunLoop.main.add(timer, forMode: .common); pollTimer = timer
      }
    }
    if !(live && !isAway && (needsRecovery || error != nil)) {
      recoveryTimer?.invalidate(); recoveryTimer = nil; scheduledRecovery = nil; recoveryAttempt = 0
    } else if recoveryTimer == nil && !busy {
      let delay = recoverySchedule(recoveryAttempt); scheduledRecovery = delay
      let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
        MainActor.assumeIsolated {
          guard let self else { return }
          self.recoveryTimer = nil; self.scheduledRecovery = nil; self.recoveryAttempt += 1; self.poll()
        }
      }
      timer.tolerance = min(1, delay / 10); RunLoop.main.add(timer, forMode: .common); recoveryTimer = timer
    }
    if liveBreak && error == nil && live && breakTimer == nil {
      let timer = Timer(timeInterval: max(0.2, remaining), repeats: false) { [weak self] _ in
        MainActor.assumeIsolated { self?.breakTimer = nil; self?.poll(force: true) }
      }
      timer.tolerance = 0.2; RunLoop.main.add(timer, forMode: .common); breakTimer = timer
    } else if !liveBreak || error != nil || !live { breakTimer?.invalidate(); breakTimer = nil }
    configureActivity()
  }
  private func configureActivity() {
    let wanted = monitoring && !stopped && !isAway && state?.phase == .focus && (state?.paused == false || needsRecovery)
    if wanted, activity == nil {
      activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep, reason: "Pomodoro focus checkpoints")
    } else if !wanted, let token = activity { ProcessInfo.processInfo.endActivity(token); activity = nil }
  }
  func updatePresentation() {
    configureTimers()
    if window != nil {
      func show(_ field: NSTextField?, _ text: String) { if let field, field.stringValue != text { field.stringValue = text } }
      show(titleField, summary)
      if let state {
        show(detailField, "\(state.completedRounds) completed · \(state.roundsPerSet) rounds per set\n\(state.domains.filter { !$0.hasPrefix("www.") }.joined(separator: ", "))\nBreaks do not automatically unblock sites. Starting the next focus blocks the selected sites again.")
      } else { show(detailField, "\(preferences.focusMinutes) min focus · \(preferences.shortBreakMinutes) min short break · \(preferences.longBreakMinutes) min long break\nBlocks \(preferences.presetNames.map { $0.capitalized }.joined(separator: " + ")) for focused work.") }
      show(errorField, error ?? stalledNote ?? (busy ? "Updating…" : ""))
      if let state {
        switch state.phase {
        case .focus: primaryButton?.title = state.paused ? "Resume Focus" : "Pause Focus"
        case .ready: primaryButton?.title = "Start Next Focus"
        case .shortBreak, .longBreak: primaryButton?.title = "Break in Progress"
        }
        primaryButton?.isEnabled = !busy && !isAway && !state.isBreak
        stopButton?.isEnabled = !busy && state.phase != .focus
        stopButton?.toolTip = state.phase == .focus ? "Finish the current focus round before stopping Pomodoro." : "Stop this timer. Existing site blocks remain in place."
      } else { primaryButton?.title = "Start Focus"; primaryButton?.isEnabled = !busy && !isAway; stopButton?.isEnabled = false; stopButton?.toolTip = "No Pomodoro timer is running." }
    }
    onChange()
  }
  func showControls() {
    if window == nil {
      let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 470, height: 372), styleMask: [.titled, .closable], backing: .buffered, defer: false)
      panel.title = "Pomodoro"; panel.isReleasedWhenClosed = false
      let root = HealthSettingsBackground(frame: panel.contentView!.bounds); panel.contentView = root
      func label(_ frame: NSRect, size: CGFloat = 13) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: ""); field.frame = frame; field.font = .systemFont(ofSize: size); root.addSubview(field); return field
      }
      titleField = label(NSRect(x: 22, y: 318, width: 426, height: 30), size: 22)
      titleField?.font = .monospacedDigitSystemFont(ofSize: 22, weight: .semibold)
      detailField = label(NSRect(x: 22, y: 178, width: 426, height: 126)); detailField?.textColor = .secondaryLabelColor
      errorField = label(NSRect(x: 22, y: 122, width: 426, height: 40), size: 11); errorField?.textColor = .systemOrange
      let primary = HealthButton("Start Focus") { [weak self] in self?.primaryAction() }; primary.frame = NSRect(x: 20, y: 76, width: 200, height: 32); root.addSubview(primary); primaryButton = primary
      let stop = HealthButton("Stop Pomodoro") { [weak self] in self?.stopFutureCycles() }; stop.frame = NSRect(x: 230, y: 76, width: 220, height: 32); root.addSubview(stop); stopButton = stop
      let settings = HealthButton("Durations & Sites…") { [weak self] in self?.showSettings() }; settings.frame = NSRect(x: 20, y: 24, width: 150, height: 32); root.addSubview(settings)
      let retry = HealthButton("Refresh Status") { [weak self] in self?.retry() }; retry.frame = NSRect(x: 292, y: 24, width: 158, height: 32); root.addSubview(retry)
      window = panel
    }
    updatePresentation(); window?.center(); window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
  }
  func showSettings() {
    if settings == nil {
      let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 420), styleMask: [.titled, .closable], backing: .buffered, defer: false)
      panel.title = "Pomodoro Settings"; panel.isReleasedWhenClosed = false
      let root = HealthSettingsBackground(frame: panel.contentView!.bounds); panel.contentView = root
      for (index, title) in ["Focus minutes (1–1440)", "Short break minutes (1–240)", "Long break minutes (1–240)", "Rounds per set (1–12)"].enumerated() {
        let y = CGFloat(370 - index * 38)
        let label = NSTextField(labelWithString: title); label.frame = NSRect(x: 22, y: y, width: 300, height: 24); root.addSubview(label)
        let field = NSTextField(string: ""); field.frame = NSRect(x: 340, y: y, width: 90, height: 24); field.setAccessibilityLabel(title); root.addSubview(field); settingFields.append(field)
      }
      for (index, name) in ["social", "news", "video"].enumerated() {
        let button = NSButton(checkboxWithTitle: name.capitalized, target: nil, action: nil)
        button.frame = NSRect(x: 22 + index * 140, y: 210, width: 135, height: 24); root.addSubview(button); presetButtons[name] = button
      }
      let selectionInfo = NSTextField(wrappingLabelWithString: "Site selection applies when starting a new timer. Current rounds keep their existing sites.")
      selectionInfo.frame = NSRect(x: 22, y: 153, width: 416, height: 46); selectionInfo.font = .systemFont(ofSize: 11); selectionInfo.textColor = .secondaryLabelColor; root.addSubview(selectionInfo)
      let info = NSTextField(wrappingLabelWithString: "Changes apply to the next focus. Blocks already started keep their existing restrictions; stopping Pomodoro does not unblock them.")
      info.frame = NSRect(x: 22, y: 86, width: 416, height: 58); info.font = .systemFont(ofSize: 11); info.textColor = .secondaryLabelColor; root.addSubview(info)
      let error = NSTextField(wrappingLabelWithString: ""); error.frame = NSRect(x: 22, y: 54, width: 416, height: 30); error.font = .systemFont(ofSize: 11); error.textColor = .systemRed; root.addSubview(error); settingsError = error
      let save = HealthButton("Save Settings") { [weak self] in self?.saveSettings() }; save.frame = NSRect(x: 270, y: 16, width: 170, height: 32); root.addSubview(save)
      settings = panel
    }
    for (field, value) in zip(settingFields, preferences.arguments) { field.stringValue = value }
    for (name, button) in presetButtons { button.state = preferences.presetNames.contains(name) ? .on : .off }
    settingsError?.stringValue = ""; settings?.center(); settings?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
  }
  func saveSettings() {
    settingsError?.textColor = .systemRed
    let values = settingFields.compactMap { Int($0.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)) }
    guard values.count == 4 else { settingsError?.stringValue = "Enter whole numbers in each field."; return }
    let value = PomodoroPreferences(focusMinutes: values[0], shortBreakMinutes: values[1], longBreakMinutes: values[2], roundsPerSet: values[3], presetNames: ["social", "news", "video"].filter { presetButtons[$0]?.state == .on })
    guard value.valid else { settingsError?.stringValue = "Use the ranges shown and choose at least one site group."; return }
    do { defaults.set(try JSONEncoder().encode(value), forKey: PomodoroPreferences.defaultsKey); preferences = value; settingsError?.textColor = .secondaryLabelColor; settingsError?.stringValue = "Saved for future focus. Site choices apply to a new timer."; updatePresentation() }
    catch { settingsError?.stringValue = error.localizedDescription }
  }
  private func hideNotice() {
    noticeTimer?.invalidate(); noticeTimer = nil; notice?.orderOut(nil)
  }
  func hideConfirmation() { confirmationTimer?.invalidate(); confirmationTimer = nil; confirmation?.orderOut(nil) }
  private func showConfirmation(started: Bool) {
    guard !stopped, let state else { return }
    let title = started && state.phase == .focus ? "Focus started · \(countdown)" : summary
    let detail = state.stalled == true ? "Progress stopped · End Stalled Round… in Raycast"
      : state.paused && state.pauseReason == "manual" ? "Paused · resume it from the Health Breaks menu" : blockedGroups(state)
    confirmationText = (title, detail)
    let size = NSSize(width: 330, height: 64)
    let panel = confirmation ?? PomodoroConfirmationPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    panel.title = title; panel.level = .floating; panel.isReleasedWhenClosed = false; panel.hidesOnDeactivate = false; panel.ignoresMouseEvents = true
    panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true; panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
    let root = NSVisualEffectView(frame: NSRect(origin: .zero, size: size)); root.material = .hudWindow; root.state = .active; root.wantsLayer = true; root.layer?.cornerRadius = 14
    let icon = NSImageView(frame: NSRect(x: 16, y: 18, width: 28, height: 28)); icon.image = NSImage(systemSymbolName: "timer", accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 20, weight: .medium)); icon.contentTintColor = .systemTeal; root.addSubview(icon)
    let heading = NSTextField(labelWithString: title); heading.frame = NSRect(x: 56, y: 33, width: size.width - 70, height: 19); heading.font = .monospacedDigitSystemFont(ofSize: 14, weight: .semibold); heading.lineBreakMode = .byTruncatingTail; root.addSubview(heading)
    let subtitle = NSTextField(labelWithString: detail); subtitle.frame = NSRect(x: 56, y: 13, width: size.width - 70, height: 17); subtitle.font = .systemFont(ofSize: 12); subtitle.textColor = .secondaryLabelColor; subtitle.lineBreakMode = .byTruncatingTail; root.addSubview(subtitle)
    panel.contentView = root
    if let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main { panel.setFrameOrigin(NSPoint(x: screen.visibleFrame.maxX - size.width - 20, y: screen.visibleFrame.maxY - size.height - 20)) }
    confirmation = panel; panel.orderFrontRegardless()
    NSAccessibility.post(element: panel, notification: .announcementRequested, userInfo: [.announcement: "\(title). \(detail)", .priority: NSAccessibilityPriorityLevel.medium.rawValue])
    confirmationTimer?.invalidate()
    let timer = Timer(timeInterval: 3, repeats: false) { [weak self] _ in MainActor.assumeIsolated { self?.hideConfirmation() } }
    RunLoop.main.add(timer, forMode: .common); confirmationTimer = timer
  }
  private func showNotice(_ state: PomodoroState) {
    let ready = state.phase == .ready
    let panel = notice ?? NSPanel(contentRect: NSRect(x: 0, y: 0, width: 370, height: 156), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    panel.title = ready ? "Ready for your next focus" : "Pomodoro Break"; panel.level = .floating; panel.isReleasedWhenClosed = false; panel.hidesOnDeactivate = false
    panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true; panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
    let root = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 370, height: 156)); root.material = .hudWindow; root.state = .active; root.wantsLayer = true; root.layer?.cornerRadius = 16
    let title = NSTextField(labelWithString: ready ? "Ready for your next focus" : "Focus complete · \(state.title)"); title.frame = NSRect(x: 20, y: 115, width: 330, height: 22); title.font = .systemFont(ofSize: 17, weight: .semibold); root.addSubview(title)
    let detail = NSTextField(wrappingLabelWithString: ready ? "Your break is complete. Start the next round whenever you are ready." : "Rest your eyes and move a little. Your next focus starts when you choose."); detail.frame = NSRect(x: 20, y: 60, width: 330, height: 46); detail.font = .systemFont(ofSize: 12); root.addSubview(detail)
    let dismiss = HealthButton(ready ? "Later" : "Enjoy Break") { [weak self] in self?.hideNotice() }; dismiss.frame = NSRect(x: 20, y: 18, width: 160, height: 30); root.addSubview(dismiss)
    let controls = HealthButton(ready ? "Start Next Round" : "Pomodoro…") { [weak self] in
      guard let self else { return }
      if ready && (self.state?.phase != .ready || self.isAway || self.busy) { return }
      self.hideNotice()
      if ready { self.primaryAction() } else { self.showControls() }
    }; controls.frame = NSRect(x: 190, y: 18, width: 160, height: 30); root.addSubview(controls)
    panel.contentView = root
    if let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main { panel.setFrameOrigin(NSPoint(x: screen.visibleFrame.maxX - 390, y: screen.visibleFrame.maxY - 176)) }
    notice = panel; panel.orderFrontRegardless()
    noticeTimer?.invalidate(); noticeTimer = Timer.scheduledTimer(withTimeInterval: 45, repeats: false) { [weak self] _ in MainActor.assumeIsolated { self?.hideNotice() } }
  }
}
