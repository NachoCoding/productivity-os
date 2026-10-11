import AppKit

private actor PomodoroReplies {
  struct Reply { var command: String; var value: PomodoroState?; var delay: UInt64 = 0 }
  var replies: [Reply]
  var calls: [[String]] = []
  var running = 0, maximumRunning = 0
  init(_ replies: [Reply]) { self.replies = replies }
  func send(_ arguments: [String]) async throws -> Data {
    running += 1; maximumRunning = max(maximumRunning, running)
    defer { running -= 1 }
    calls.append(arguments)
    guard !replies.isEmpty else { throw PomodoroError.unavailable("Unexpected command: \(arguments)") }
    let reply = replies.removeFirst()
    guard arguments.first == reply.command else { throw PomodoroError.unavailable("Expected \(reply.command), got \(arguments)") }
    if reply.delay > 0 { try await Task.sleep(nanoseconds: reply.delay) }
    return try JSONEncoder().encode(reply.value)
  }
}

@MainActor func windowText(_ window: NSWindow?, contains text: String) -> Bool {
  func find(in view: NSView) -> Bool { (view as? NSTextField)?.stringValue.contains(text) == true || view.subviews.contains(where: find) }
  return window?.contentView.map(find) ?? false
}

@MainActor func runPomodoroTests(root: URL) async throws {
  func focus(paused: Bool = false, reason: String? = nil) -> PomodoroState {
    PomodoroState(phase: .focus, paused: paused, pauseReason: reason, remainingMs: 1_500_000, endsAt: 2_500_000,
      focusMinutes: 25, shortBreakMinutes: 5, longBreakMinutes: 15, roundsPerSet: 4, completedRounds: 0,
      label: "Pomodoro", domains: ["example.test", "www.example.test"])
  }
  func controller(_ backend: PomodoroReplies, defaults: UserDefaults, clock: @escaping () -> TimeInterval = { 100 }) -> PomodoroController {
    PomodoroController(defaults: defaults, client: PomodoroClient(transport: { try await backend.send($0) }), monitorID: "test-monitor",
      domainProvider: { _ in ["example.test", "www.example.test"] }, uptime: clock, now: { Date(timeIntervalSince1970: 1000) })
  }
  let suite = "pomodoro-qa-\(UUID().uuidString)", defaults = UserDefaults(suiteName: suite)!
  defer { defaults.removePersistentDomain(forName: suite) }
  let healthData = try JSONEncoder().encode(BreakPreferences())
  defaults.set(healthData, forKey: "preferences")
  check(PomodoroPreferences.load(defaults) == PomodoroPreferences(), "Pomodoro defaults are 25/5/15/4 with Social + News")
  var invalid = PomodoroPreferences(); invalid.shortBreakMinutes = 241
  defaults.set(try JSONEncoder().encode(invalid), forKey: PomodoroPreferences.defaultsKey)
  check(PomodoroPreferences.load(defaults).shortBreakMinutes == 5, "Invalid saved Pomodoro durations fall back without altering reminder settings")
  defaults.removeObject(forKey: PomodoroPreferences.defaultsKey)
  let presetData = try Data(contentsOf: URL(fileURLWithPath: "assets/block-presets.json"))
  let domains = try PomodoroPresets.domains(data: presetData)
  check(domains.contains("instagram.com") && domains.contains("www.bbc.com") && !domains.contains("youtube.com"), "Native default block domains derive from shared Social + News presets")
  check(try PomodoroPresets.domains(data: presetData, selected: ["video"]).contains("www.youtube.com"), "Optional Video selection expands the shared bare domains")

  var clock = PomodoroDisplayClock(); clock.accept(focus(), uptime: 100)
  check(clock.remaining(uptime: 105, date: Date()) == 1495, "One-second display interpolation does not require helper calls")
  check(abs(clock.remaining(uptime: 111.9, date: Date()) - 1488.1) < 0.000_1, "A checkpoint reply arriving late within the helper's 15 s credit does not freeze the countdown")
  check(clock.remaining(uptime: 999, date: Date()) == 1485, "A stalled monitor never displays unbounded unacknowledged focus time")
  let tickDelay = PomodoroDisplayClock.tickDelay(remaining: 1494.3)
  check(abs(tickDelay - 0.32) < 0.000_1 && Int(ceil(1494.3)) == 1495 && Int(ceil(1494.3 - tickDelay)) == 1494
    && Int(ceil(1494.3 - tickDelay - 0.05)) == 1494 && Int(ceil(1494.3 - tickDelay - 1)) == 1493,
    "Display ticks land just after each displayed second changes, within their timer tolerance")
  check((0..<6).map { PomodoroRecovery.delay(after: $0) } == [2, 10, 10, 10, 30, 30], "Stuck pauses and helper errors retry after 2 s, then every 10 s, then every 30 s")
  clock.away = true
  check(clock.remaining(uptime: 999, date: Date()) == 1500 && !clock.focusRunning, "Focus display freezes immediately while Mac is away")
  clock.away = false; clock.accept(focus(paused: true, reason: "manual"), uptime: 100)
  check(clock.remaining(uptime: 500, date: Date()) == 1500 && !clock.focusRunning, "Manual pause freezes the display estimate")
  var rest = focus(); rest.phase = .shortBreak; rest.remainingMs = 300_000; rest.endsAt = 1_300_000; rest.completedRounds = 1
  clock.accept(rest, uptime: 100); clock.away = true
  check(clock.remaining(uptime: 999, date: Date(timeIntervalSince1970: 1240)) == 60, "Break countdown continues by its wall-clock deadline while away")
  check(clock.remaining(uptime: 999, date: Date(timeIntervalSince1970: 1400)) == 0, "Expired breaks stop at zero and cannot create another focus")

  // Captured from blocker.sh itself with a private hosts file and deterministic clock.
  for (name, phase, paused) in [("focus", PomodoroState.Phase.focus, true), ("running", .focus, false), ("break", .shortBreak, false)] {
    let data = try Data(contentsOf: URL(fileURLWithPath: "tests/health-breaks/fixtures/\(name).json"))
    let decoded = try await PomodoroClient(transport: { _ in data }).request(["pomodoro-status"])
    check(decoded?.phase == phase && decoded?.paused == paused && decoded?.remainingMs == 60000 && decoded?.domains == ["example.com", "www.example.com"], "Native client decodes actual privileged helper \(name) response")
  }

  let v3Reply = try Data(contentsOf: URL(fileURLWithPath: "tests/health-breaks/fixtures/running.json"))
  let v3State = try await PomodoroClient(transport: { _ in v3Reply }).request(["pomodoro-status"])
  var stalledState = focus(paused: true, reason: "monitor"); stalledState.stalled = true
  let stalledReply = try JSONEncoder().encode(stalledState)
  let decodedStalled = try await PomodoroClient(transport: { _ in stalledReply }).request(["pomodoro-status"])
  check(v3State?.stalled == nil && decodedStalled?.stalled == true, "Blocker v4's stalled flag decodes while v3 replies without it stay valid")

  let invalidReply = PomodoroClient(transport: { _ in Data("{\"phase\":\"invalid\"}".utf8) })
  do { _ = try await invalidReply.request(["pomodoro-status"]); check(false, "Malformed helper response rejected") }
  catch { check(error is PomodoroError, "Malformed helper response reports a useful connection error") }
  let nullReply = PomodoroClient(transport: { _ in Data("null".utf8) })
  let noPlan = try await nullReply.request(["pomodoro-status"])
  check(noPlan == nil, "No active plan is represented by helper JSON null")

  // Exercise the actual nonblocking process transport without sudo or privileged state.
  func openDescriptors() -> Int { (0..<1024).filter { fcntl(Int32($0), F_GETFD) >= 0 }.count }
  let descriptorsBefore = openDescriptors()
  for index in 0..<30 {
    let data = try await PomodoroProcess.run(arguments: ["-c", "printf null"], executable: "/bin/sh", prefix: [])
    check(data == Data("null".utf8), "Fast helper exit preserves complete stdout (\(index + 1))")
  }
  try await Task.sleep(nanoseconds: 50_000_000)
  check(openDescriptors() <= descriptorsBefore + 4, "Thirty helper calls do not accumulate pipe descriptors")
  let both = try await PomodoroProcess.run(arguments: ["-c", "printf null; printf diagnostic >&2"], executable: "/bin/sh", prefix: [])
  check(both == Data("null".utf8), "Transport drains both pipes while keeping stderr out of JSON")
  do {
    _ = try await PomodoroProcess.run(arguments: ["-c", "printf '%s' '{\"code\":\"setup\",\"message\":\"Run Setup in Raycast.\"}' >&2; exit 2"], executable: "/bin/sh", prefix: [])
    check(false, "Failed helper command rejected")
  } catch { check(error.localizedDescription == "Run Setup in Raycast.", "Structured helper error displays its message rather than raw JSON") }
  let timeoutStart = ProcessInfo.processInfo.systemUptime
  do { _ = try await PomodoroProcess.run(arguments: ["2"], executable: "/bin/sleep", prefix: [], timeout: 0.05); check(false, "Unresponsive process times out") }
  catch { check(ProcessInfo.processInfo.systemUptime - timeoutStart < 1 && error.localizedDescription.contains("did not respond"), "Process deadline returns promptly without blocking AppKit") }
  do { _ = try await PomodoroProcess.run(arguments: ["-c", "70000", "/dev/zero"], executable: "/usr/bin/head", prefix: []); check(false, "Oversized process output rejected") }
  catch { check(error.localizedDescription.contains("too much data"), "Process transport enforces a combined bounded output limit") }

  let manual = PomodoroReplies([.init(command: "pomodoro-status", value: focus(paused: true, reason: "manual")), .init(command: "pomodoro-checkpoint", value: focus(paused: true, reason: "manual")), .init(command: "pomodoro-pause", value: focus(paused: true, reason: "manual")), .init(command: "pomodoro-checkpoint", value: focus(paused: true, reason: "manual"))])
  let manualController = controller(manual, defaults: defaults)
  manualController.startMonitoring(timers: false); await manualController.waitForIdle()
  let manualBeforePoll = await manual.calls.count
  for _ in 0..<5 { manualController.poll() }
  await manualController.waitForIdle()
  let manualAfterPoll = await manual.calls.count
  check(manualBeforePoll == manualAfterPoll, "Manual pause never launches background helper polls")
  manualController.setAway(true); manualController.setAway(false); await manualController.waitForIdle()
  let manualCalls = await manual.calls
  check(manualController.state?.pauseReason == "manual" && !manualCalls.contains(where: { $0.first == "pomodoro-resume" }), "Reopen and unlock preserve manual pause instead of force-resuming it")
  manualController.shutdown()

  let recovery = PomodoroReplies([.init(command: "pomodoro-status", value: focus()), .init(command: "pomodoro-checkpoint", value: focus(paused: true, reason: "monitor")), .init(command: "pomodoro-checkpoint", value: focus())])
  let recoveryController = controller(recovery, defaults: defaults)
  recoveryController.startMonitoring(timers: false); await recoveryController.waitForIdle()
  check(recoveryController.state?.pauseReason == "monitor" && !recoveryController.focusRunning, "Unavailable desktop probe keeps focus paused despite successful helper JSON")
  recoveryController.poll(); await recoveryController.waitForIdle()
  let recoveryCalls = await recovery.calls
  check(recoveryCalls.map { $0[0] } == ["pomodoro-status", "pomodoro-checkpoint", "pomodoro-checkpoint"] && recoveryController.focusRunning, "Monitor pause retries its checkpoint and recovers without a manual Resume click")
  recoveryController.shutdown()

  // An unlock can race the root probe: the helper still reports away although this Mac is present.
  var recoveryAttempts: [Int] = []
  let racing = PomodoroReplies([.init(command: "pomodoro-status", value: focus()), .init(command: "pomodoro-checkpoint", value: focus(paused: true, reason: "away")), .init(command: "pomodoro-checkpoint", value: focus())])
  let racingController = PomodoroController(defaults: defaults, client: PomodoroClient(transport: { try await racing.send($0) }), monitorID: "test-monitor",
    domainProvider: { _ in ["example.test", "www.example.test"] }, uptime: { 100 }, now: { Date(timeIntervalSince1970: 1000) },
    recoverySchedule: { recoveryAttempts.append($0); return 0.05 })
  racingController.startMonitoring(); await racingController.waitForIdle()
  check(racingController.needsRecovery && !racingController.isAway && racingController.scheduledRecovery == 0.05 && recoveryAttempts == [0] && racingController.holdsActivity,
    "An away reply while the Mac is present schedules the first checkpoint retry and keeps App Nap off while recovering")
  var waited = 0
  while !racingController.focusRunning && waited < 80 { try await Task.sleep(nanoseconds: 25_000_000); waited += 1 }
  await racingController.waitForIdle()
  let racingCalls = await racing.calls
  check(racingCalls.map { $0[0] } == ["pomodoro-status", "pomodoro-checkpoint", "pomodoro-checkpoint"] && racingController.focusRunning
    && racingController.scheduledRecovery == nil && racingController.recoveryAttempt == 0 && recoveryAttempts == [0],
    "A paused/away reply while present recovers on the retry schedule without a manual Resume")
  racingController.shutdown()
  check(!racingController.holdsActivity, "Shutdown releases the App Nap activity")

  let activityBackend = PomodoroReplies([.init(command: "pomodoro-status", value: focus()), .init(command: "pomodoro-checkpoint", value: focus()), .init(command: "pomodoro-pause", value: focus(paused: true, reason: "manual"))])
  let activityController = controller(activityBackend, defaults: defaults)
  let heldBeforeMonitoring = activityController.holdsActivity
  activityController.startMonitoring(timers: false); await activityController.waitForIdle()
  let heldWhileRunning = activityController.holdsActivity
  activityController.primaryAction(); await activityController.waitForIdle()
  check(!heldBeforeMonitoring && heldWhileRunning && activityController.state?.pauseReason == "manual" && !activityController.holdsActivity,
    "App Nap protection is held only while focus runs and is released by a manual pause")
  activityController.shutdown()

  let stalledBackend = PomodoroReplies([.init(command: "pomodoro-status", value: stalledState), .init(command: "pomodoro-checkpoint", value: stalledState)])
  let stalledController = controller(stalledBackend, defaults: defaults)
  stalledController.startMonitoring(timers: false); await stalledController.waitForIdle()
  stalledController.showControls()
  check(stalledController.summary == "Focus 25:00 · Stalled" && windowText(stalledController.window, contains: "End Stalled Round…")
    && windowText(stalledController.window, contains: "Raycast → Blocked Sites"), "A stalled round explains that progress stopped and points to Raycast's End Stalled Round review")
  if let view = stalledController.window?.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
    view.cacheDisplay(in: view.bounds, to: rep); try rep.representation(using: .png, properties: [:])?.write(to: root.appendingPathComponent("pomodoro-stalled.png"))
  }
  stalledController.window?.close(); stalledController.shutdown()

  let dormant = PomodoroReplies([.init(command: "pomodoro-status", value: nil)])
  let dormantController = controller(dormant, defaults: defaults)
  dormantController.startMonitoring(timers: false); await dormantController.waitForIdle()
  for _ in 0..<5 { dormantController.poll(); dormantController.tick() }
  await dormantController.waitForIdle()
  let dormantCalls = await dormant.calls.count
  check(dormantCalls == 1, "An idle Pomodoro helper does not poll after initial discovery")
  dormantController.shutdown()

  var now: TimeInterval = 100
  var awayState = focus(paused: true, reason: "away")
  awayState.remainingMs = 1_495_000
  let serial = PomodoroReplies([.init(command: "pomodoro-status", value: focus(), delay: 30_000_000), .init(command: "pomodoro-checkpoint", value: focus()), .init(command: "pomodoro-pause", value: awayState, delay: 30_000_000), .init(command: "pomodoro-checkpoint", value: focus())])
  let serialController = controller(serial, defaults: defaults, clock: { now })
  serialController.startMonitoring(timers: false); await serialController.waitForIdle()
  now = 105; serialController.setAway(true)
  check(serialController.remaining == 1495 && !serialController.focusRunning, "System lock freezes the visible focus immediately, before asynchronous helper reply")
  check(!serialController.holdsActivity, "Going away releases the App Nap activity")
  now = 500; serialController.setAway(false)
  check(serialController.remaining == 1495 && !serialController.focusRunning, "Unlock waits for helper acknowledgement before the display resumes")
  await serialController.waitForIdle()
  let serialCalls = await serial.calls, maxConcurrent = await serial.maximumRunning
  check(maxConcurrent == 1 && serialCalls.map { $0[0] } == ["pomodoro-status", "pomodoro-checkpoint", "pomodoro-pause", "pomodoro-checkpoint"], "Focus lifecycle commands remain ordered with at most one process in flight")
  let tickCallCount = serialCalls.count
  for _ in 0..<10 { serialController.tick() }
  let afterTicks = await serial.calls.count
  check(afterTicks == tickCallCount, "Ten local countdown updates produce no helper requests")
  serialController.shutdown()

  let alreadyActive = PomodoroReplies([.init(command: "pomodoro-status", value: focus())])
  let activeController = controller(alreadyActive, defaults: defaults)
  activeController.startOrShow(); await activeController.waitForIdle()
  let activeCalls = await alreadyActive.calls.count
  check(activeCalls == 1, "One-click start opens an existing plan without creating another block session")
  activeController.window?.close(); activeController.shutdown()

  let silentBackend = PomodoroReplies([.init(command: "pomodoro-status", value: nil), .init(command: "start-pomodoro", value: focus(paused: true, reason: "monitor")), .init(command: "pomodoro-checkpoint", value: focus())])
  let silent = controller(silentBackend, defaults: defaults)
  let keyBeforeSilent = NSApp.keyWindow
  silent.startSilently(); await silent.waitForIdle()
  let silentCalls = await silentBackend.calls
  check(silentCalls.map { $0[0] } == ["pomodoro-status", "start-pomodoro", "pomodoro-checkpoint"] && silentCalls[1] == ["start-pomodoro", "25", "5", "15", "4", "Pomodoro", "example.test", "www.example.test"],
    "Silent start creates a plan with the same helper contract as the controls")
  check(silent.window == nil && silent.settings == nil && NSApp.keyWindow === keyBeforeSilent && silent.confirmation?.isVisible == true && silent.confirmation?.isKeyWindow == false
    && silent.confirmation?.canBecomeKey == false && silent.confirmation?.styleMask.contains(.nonactivatingPanel) == true,
    "Silent start opens no window and confirms with a nonactivating panel that leaves the key window unchanged")
  check(silent.confirmationText?.title == "Focus started · 25:00" && silent.confirmationText?.detail.hasPrefix("Blocking ") == true,
    "The confirmation shows the new countdown and the blocked site groups")
  if let view = silent.confirmation?.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
    view.cacheDisplay(in: view.bounds, to: rep); try rep.representation(using: .png, properties: [:])?.write(to: root.appendingPathComponent("pomodoro-confirmation.png"))
  }
  silent.shutdown()
  check(silent.confirmation?.isVisible == false, "Shutdown hides a visible confirmation")

  var readyPlan = rest; readyPlan.phase = .ready; readyPlan.remainingMs = 0; readyPlan.endsAt = nil
  let nextBackend = PomodoroReplies([.init(command: "pomodoro-status", value: readyPlan), .init(command: "pomodoro-next", value: focus())])
  let nextSilent = controller(nextBackend, defaults: defaults)
  nextSilent.startSilently(); await nextSilent.waitForIdle()
  let nextCalls = await nextBackend.calls
  check(nextCalls == [["pomodoro-status"], ["pomodoro-next", "test-monitor", "25", "5", "15", "4"]] && nextSilent.window == nil && nextSilent.confirmationText?.title == "Focus started · 25:00",
    "Silent start begins the next focus when a round is ready, without a window")
  nextSilent.shutdown()

  let runningBackend = PomodoroReplies([.init(command: "pomodoro-status", value: focus())])
  let runningSilent = controller(runningBackend, defaults: defaults)
  runningSilent.startSilently(); await runningSilent.waitForIdle()
  let runningCalls = await runningBackend.calls
  check(runningCalls == [["pomodoro-status"]] && runningSilent.window == nil && runningSilent.confirmationText?.title == "Focus 25:00",
    "Silent start only reports the status of a round that is already running")
  runningSilent.shutdown()

  let failingBackend = PomodoroReplies([])
  let failing = controller(failingBackend, defaults: defaults)
  failing.startSilently(); await failing.waitForIdle()
  check(failing.window?.isVisible == true && failing.error?.isEmpty == false && windowText(failing.window, contains: failing.error ?? "?") && failing.confirmation == nil,
    "A silent start that fails opens the Pomodoro controls with the error instead of a confirmation")
  failing.window?.close(); failing.shutdown()

  let awayStartBackend = PomodoroReplies([.init(command: "pomodoro-status", value: nil), .init(command: "pomodoro-status", value: nil)])
  let awayStarter = controller(awayStartBackend, defaults: defaults)
  awayStarter.startMonitoring(away: true, timers: false); awayStarter.startSilently(); await awayStarter.waitForIdle()
  let awayStartCalls = await awayStartBackend.calls
  check(awayStartCalls.count == 2 && awayStarter.state == nil && awayStarter.error == "Unlock your Mac before starting focus." && awayStarter.window?.isVisible == true,
    "Silent start while the Mac is away blocks nothing and explains why in the controls")
  awayStarter.window?.close(); awayStarter.shutdown()

  let begin = PomodoroReplies([.init(command: "pomodoro-status", value: nil), .init(command: "start-pomodoro", value: focus()), .init(command: "pomodoro-checkpoint", value: focus())])
  let startController = controller(begin, defaults: defaults)
  startController.startOrShow(); await startController.waitForIdle()
  let startCalls = await begin.calls
  check(startCalls[1] == ["start-pomodoro", "25", "5", "15", "4", "Pomodoro", "example.test", "www.example.test"], "Default start sends exact duration and expanded-domain helper contract")
  startController.showSettings()
  startController.settingFields[0].stringValue = "0"; startController.saveSettings()
  check(startController.preferences.focusMinutes == 25, "Invalid Pomodoro settings cannot alter an active plan or stored durations")
  startController.settingFields[0].stringValue = "50"; startController.presetButtons["video"]?.state = .on; startController.saveSettings()
  check(PomodoroPreferences.load(defaults).focusMinutes == 50 && PomodoroPreferences.load(defaults).presetNames.contains("video"), "Durations and site choices persist independently for future plans")
  check(defaults.data(forKey: "preferences") == healthData, "Pomodoro settings preserve the existing health reminder preferences byte for byte")
  for (name, view) in [("pomodoro-controls", startController.window?.contentView), ("pomodoro-settings", startController.settings?.contentView)] {
    if let view, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
      view.cacheDisplay(in: view.bounds, to: rep); try rep.representation(using: .png, properties: [:])?.write(to: root.appendingPathComponent("\(name).png"))
    }
  }
  startController.window?.close(); startController.settings?.close(); startController.shutdown()

  var ready = rest; ready.phase = .ready; ready.remainingMs = 0; ready.endsAt = nil
  let breakBackend = PomodoroReplies([.init(command: "pomodoro-status", value: focus()), .init(command: "pomodoro-checkpoint", value: focus()), .init(command: "pomodoro-checkpoint", value: rest), .init(command: "pomodoro-status", value: ready), .init(command: "pomodoro-next", value: focus()), .init(command: "pomodoro-checkpoint", value: rest), .init(command: "pomodoro-stop", value: nil)])
  let breaks = controller(breakBackend, defaults: defaults)
  breaks.startMonitoring(timers: false); await breaks.waitForIdle()
  let keyBefore = NSApp.keyWindow
  breaks.poll(); await breaks.waitForIdle()
  check(breaks.notice?.isVisible == true && NSApp.keyWindow === keyBefore && breaks.notice?.isKeyWindow == false, "Focus completion shows a quiet break notification without taking keyboard focus")
  if let view = breaks.notice?.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
    view.cacheDisplay(in: view.bounds, to: rep); try rep.representation(using: .png, properties: [:])?.write(to: root.appendingPathComponent("pomodoro-break.png"))
  }
  let beforeAway = await breakBackend.calls.count
  for _ in 0..<5 { breaks.poll() }
  await breaks.waitForIdle()
  let afterBreakPoll = await breakBackend.calls.count
  check(afterBreakPoll == beforeAway, "Breaks use a deadline instead of periodic helper polling")
  breaks.setAway(true); await breaks.waitForIdle()
  let afterAway = await breakBackend.calls.count
  check(afterAway == beforeAway, "Going away during a break does not send a focus pause command")
  breaks.setAway(false); await breaks.waitForIdle()
  let readyCalls = await breakBackend.calls
  check(breaks.state?.phase == .ready && !readyCalls.contains(where: { $0.first == "pomodoro-next" }), "Finished break waits for an explicit next-focus action")
  check(breaks.notice?.isVisible == true && breaks.notice?.title == "Ready for your next focus" && NSApp.keyWindow === keyBefore && breaks.notice?.isKeyWindow == false, "Returning after an elapsed break shows one quiet next-focus notification without stealing focus")
  if let view = breaks.notice?.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
    view.cacheDisplay(in: view.bounds, to: rep); try rep.representation(using: .png, properties: [:])?.write(to: root.appendingPathComponent("pomodoro-ready.png"))
  }
  for _ in 0..<5 { breaks.poll() }
  await breaks.waitForIdle()
  let afterReadyPoll = await breakBackend.calls.count
  check(afterReadyPoll == readyCalls.count, "Ready-for-next-focus mode launches no background helper polls")
  let nextButton = breaks.notice?.contentView?.subviews.compactMap { $0 as? HealthButton }.first { $0.title == "Start Next Round" }
  check(nextButton != nil, "Ready popup offers an explicit Start Next Round action")
  nextButton?.performClick(nil); await breaks.waitForIdle()
  let afterNext = await breakBackend.calls
  check(breaks.state?.phase == .focus && breaks.notice?.isVisible == false && afterNext.filter { $0.first == "pomodoro-next" }.count == 1, "Clicking Start Next Round starts exactly one focus and hides the popup")
  let beforeStop = await breakBackend.calls.count
  breaks.stopFutureCycles(); await breaks.waitForIdle()
  let afterStop = await breakBackend.calls.count
  check(afterStop == beforeStop, "Native controls cannot stop an unfinished focus round")
  breaks.poll(); await breaks.waitForIdle(); breaks.stopFutureCycles(); await breaks.waitForIdle()
  check(breaks.state == nil, "Stop future cycles becomes available once the current focus has finished")
  breaks.shutdown()

  let awakeBackend = PomodoroReplies([.init(command: "pomodoro-status", value: rest), .init(command: "pomodoro-status", value: ready), .init(command: "pomodoro-status", value: ready), .init(command: "pomodoro-status", value: ready)])
  let awake = controller(awakeBackend, defaults: defaults)
  awake.startMonitoring(timers: false); await awake.waitForIdle()
  awake.poll(force: true); await awake.waitForIdle()
  let awakeCalls = await awakeBackend.calls
  check(awake.notice?.isVisible == true && awake.notice?.title == "Ready for your next focus" && !awakeCalls.contains(where: { $0.first == "pomodoro-next" }), "An awake break-to-ready transition notifies without starting focus or blocking sites again")
  let later = awake.notice?.contentView?.subviews.compactMap { $0 as? HealthButton }.first { $0.title == "Later" }
  later?.performClick(nil); awake.poll(force: true); await awake.waitForIdle()
  check(awake.notice?.isVisible == false && awake.state?.completedRounds == ready.completedRounds, "Later dismisses the ready notice; repeated status neither replays it nor completes another round")
  awake.setAway(true); await awake.waitForIdle(); awake.setAway(false); await awake.waitForIdle()
  check(awake.notice?.isVisible == false, "Returning again cannot replay an already acknowledged ready notification")
  awake.shutdown()

  let awayBackend = PomodoroReplies([.init(command: "pomodoro-status", value: rest), .init(command: "pomodoro-status", value: ready), .init(command: "pomodoro-status", value: ready), .init(command: "pomodoro-status", value: ready)])
  let away = controller(awayBackend, defaults: defaults)
  away.startMonitoring(timers: false); await away.waitForIdle()
  away.setAway(true); await away.waitForIdle(); away.poll(force: true); await away.waitForIdle()
  check(away.state?.phase == .ready && away.notice?.isVisible != true, "A break that completes while away defers the notification")
  away.setAway(false); await away.waitForIdle()
  check(away.notice?.isVisible == true && away.notice?.title == "Ready for your next focus", "Deferred break completion produces one notification on return")
  away.setAway(true); await away.waitForIdle()
  check(away.notice?.isVisible == false, "Going away hides an already visible ready notification")
  away.setAway(false); await away.waitForIdle()
  let awayCalls = await awayBackend.calls
  check(away.notice?.isVisible == false && !awayCalls.contains(where: { $0.first == "pomodoro-next" }), "A second return neither repeats the notification nor starts a focus")
  away.shutdown()

  // The status menu is built once; an open menu keeps the same item objects and shows live progress.
  let menuApp = HealthApp(); menuApp.defaults = defaults
  let menuBackend = PomodoroReplies([.init(command: "pomodoro-status", value: focus()), .init(command: "pomodoro-checkpoint", value: focus())])
  menuApp.pomodoro = PomodoroController(defaults: defaults, client: PomodoroClient(transport: { try await menuBackend.send($0) }), monitorID: "test-monitor",
    domainProvider: { _ in [] }, uptime: { 100 }, now: { Date(timeIntervalSince1970: 1000) }, onChange: { [weak menuApp] in menuApp?.refreshPomodoroPresentation() })
  let menu = menuApp.statusMenu, menuItem = menuApp.pomodoroMenuItem, menuCount = menu.items.count
  menuApp.menuNeedsUpdate(menu); menuApp.menuWillOpen(menu)
  let idleTitle = menuItem.title, startVisible = !menuApp.startPomodoroMenuItem.isHidden
  menuApp.pomodoro.startMonitoring(timers: false); await menuApp.pomodoro.waitForIdle()
  check(idleTitle == "Pomodoro" && startVisible && menuApp.statusMenu === menu && menuApp.pomodoroMenuItem === menuItem && menu.items.count == menuCount
    && menu.items.contains(menuItem) && menuItem.title == "Focus 25:00" && menuApp.startPomodoroMenuItem.isHidden,
    "An open status menu keeps its item objects while the Pomodoro item updates live")
  menuApp.menuDidClose(menu); menuApp.pomodoro.shutdown(); menuApp.posture.shutdown()
}
