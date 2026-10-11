import AppKit
import AVFoundation

/// An empty session satisfies preview wiring, but never has inputs or starts running.
private final class FakePostureCapture: PostureCapturing {
  let session = AVCaptureSession()
  let deliver: @MainActor (PostureCaptureEngine.Event) -> Void
  var starts: [Bool] = []
  var modes: [(calibrating: Bool, slow: Bool)] = []
  var stops = 0
  init(deliver: @escaping @MainActor (PostureCaptureEngine.Event) -> Void) { self.deliver = deliver }
  func start(calibrating: Bool) { starts.append(calibrating) }
  func setMode(calibrating: Bool, slow: Bool) { modes.append((calibrating, slow)) }
  func stop() { stops += 1 }
  @MainActor func emit(_ event: PostureCaptureEngine.Event) { deliver(event) }
}

private enum PostureFixtureError: Error { case missingWindow, missingButton(String) }

@MainActor private final class PostureFixture {
  let suite = "posture-lifecycle-qa-\(UUID().uuidString)"
  let defaults: UserDefaults
  var time: TimeInterval = 100
  var authorization: AVAuthorizationStatus = .authorized
  var permissionRequests = 0
  var permissionCompletion: (@Sendable (Bool) -> Void)?
  var captures: [FakePostureCapture] = []
  var window: NSWindow?
  var changed: (() -> Void)?
  lazy var coach = PostureCoach(defaults: defaults,
    authorizationStatus: { [unowned self] in self.authorization },
    requestCameraAccess: { [unowned self] completion in self.permissionRequests += 1; self.permissionCompletion = completion },
    makeCapture: { [unowned self] deliver in
      let capture = FakePostureCapture(deliver: deliver); self.captures.append(capture); return capture
    }, now: { [unowned self] in self.time }, onChange: { [unowned self] in self.changed?() })
  init() { defaults = UserDefaults(suiteName: suite)! }
  func open(monitoring: Bool = true) throws {
    update(monitoring: monitoring); coach.showSettings()
    guard let window = NSApp.windows.first(where: { $0.title == "Posture Coach" && $0.isVisible }) else { throw PostureFixtureError.missingWindow }
    self.window = window
  }
  func update(monitoring: Bool = true, idle: TimeInterval = 0, allowed: Bool = true) {
    coach.update(idleSeconds: idle, systemAllowed: allowed, monitoringAllowed: monitoring)
  }
  func button(_ title: String, in window: NSWindow? = nil) -> NSButton? {
    func find(in view: NSView) -> NSButton? {
      if let button = view as? NSButton, button.title == title { return button }
      for child in view.subviews { if let found = find(in: child) { return found } }
      return nil
    }
    guard let root = (window ?? self.window)?.contentView else { return nil }
    return find(in: root)
  }
  func click(_ title: String, in window: NSWindow? = nil) throws {
    guard let control = button(title, in: window), let action = control.action,
      NSApp.sendAction(action, to: control.target, from: control) else { throw PostureFixtureError.missingButton(title) }
  }
  func calibrate() throws { try click(button("Recalibrate") == nil ? "Enable & Calibrate" : "Recalibrate") }
  func containsLabel(_ text: String) -> Bool {
    func find(in view: NSView) -> Bool {
      if let label = view as? NSTextField, label.stringValue.contains(text) { return true }
      return view.subviews.contains(where: find)
    }
    return window?.contentView.map(find) ?? false
  }
  var preview: NSView? {
    func find(in view: NSView) -> NSView? {
      if view.layer?.sublayers?.contains(where: { $0 is AVCaptureVideoPreviewLayer }) == true { return view }
      for child in view.subviews { if let found = find(in: child) { return found } }
      return nil
    }
    return window?.contentView.flatMap(find)
  }
  func samples(_ count: Int, into capture: FakePostureCapture) {
    for _ in 0..<count {
      time += 0.5
      capture.emit(.observation(cameraID: "fixture-built-in", sample: PostureSample(time: time, headHeight: 0.5, shoulderWidth: 0.5)))
    }
  }
  func grantPermission() async throws {
    authorization = .authorized; permissionCompletion?(true); permissionCompletion = nil
    try await Task.sleep(nanoseconds: 10_000_000)
  }
  func finish() {
    coach.shutdown(); window?.close(); defaults.removePersistentDomain(forName: suite)
  }
}

@MainActor private func postureNotice(titled title: String) -> NSWindow? {
  func hasTitle(_ view: NSView) -> Bool {
    if let label = view as? NSTextField, label.stringValue == title { return true }
    return view.subviews.contains(where: hasTitle)
  }
  return NSApp.windows.first { $0.isVisible && $0.contentView.map(hasTitle) == true }
}

@MainActor func runPostureLifecycleTests(root: URL) async throws {
  do {
    let fixture = PostureFixture(); defer { fixture.finish() }
    try fixture.open()
    fixture.changed = { [weak fixture] in
      guard let fixture, fixture.coach.status.hasPrefix("Sit comfortably") else { return }
      fixture.update(allowed: false)
    }
    try fixture.click("Enable & Calibrate")
    check(fixture.captures.count == 1 && fixture.captures[0].stops == 1 && fixture.captures[0].starts.isEmpty,
      "A synchronous status callback cancelling calibration cannot start its orphaned capture")
  }
  do {
    let fixture = PostureFixture(); defer { fixture.finish() }
    PosturePreferences(enabled: true, baseline: PostureBaseline(cameraID: "fixture-built-in", headHeight: 0.5, shoulderWidth: 0.5)).save(fixture.defaults)
    fixture.changed = { [weak fixture] in
      guard let fixture, fixture.coach.status.hasPrefix("Starting local posture monitoring") else { return }
      fixture.update(allowed: false)
    }
    try fixture.open()
    check(fixture.captures.count == 1 && fixture.captures[0].stops == 1 && fixture.captures[0].starts.isEmpty,
      "A synchronous status callback cancelling saved-baseline monitoring cannot restart capture")
  }
  do {
    let fixture = PostureFixture(); defer { fixture.finish() }
    try fixture.open()
    check(fixture.captures.isEmpty && fixture.permissionRequests == 0,
      "Opening unconfigured posture settings never requests permission or creates capture")
    check(fixture.button("Show camera preview during calibration")?.state == .on && fixture.preview?.isHidden == true,
      "The preview defaults on for calibration but stays hidden before explicit setup")
    try fixture.click("Enable & Calibrate")
    check(fixture.captures.count == 1 && fixture.captures[0].starts == [true],
      "Enable & Calibrate starts an explicit setup session without a focus round")
    check(fixture.preview?.isHidden == false && fixture.coach.calibrationSummary.contains("not saved yet"),
      "Explicit setup shows its preview and clearly states that calibration is not saved yet")
    let capture = fixture.captures[0]
    capture.emit(.ready(cameraID: "fixture-built-in", captureFPS: 5))
    fixture.update()
    check(capture.stops == 0, "Ordinary activity updates keep the explicit calibration alive")
    fixture.samples(10, into: capture)
    check(PosturePreferences.load(fixture.defaults).baseline?.cameraID == "fixture-built-in" && capture.stops == 0
      && capture.modes.last?.calibrating == false,
      "Standalone calibration saves its baseline and starts normal monitoring without Pomodoro")
    check(capture.modes.count == 1 && !capture.modes[0].calibrating && !capture.modes[0].slow
      && PostureFrameRate.choose([(min: 1, max: 30)], calibrating: true) == 5 && PostureFrameRate.choose([(min: 1, max: 30)], calibrating: false) == 1,
      "A saved calibration switches the running camera from 5 fps calibration to its slowest monitoring frame rate")
    check(fixture.coach.calibrationSummary == "Calibration saved" && fixture.containsLabel("Calibration saved")
      && fixture.preview?.isHidden == true && fixture.button("Recalibrate") != nil,
      "Only a saved baseline reports success, hides the preview, and offers Recalibrate")
    fixture.update(); fixture.time += 5; fixture.update()
    check(fixture.captures.count == 1 && capture.stops == 0, "Monitoring continues without a Pomodoro timer or another camera session")
    fixture.update(monitoring: false)
    check(capture.stops == 1, "Health reminder pause stops automatic posture monitoring")
    let status = fixture.coach.status
    fixture.time += 3
    capture.emit(.observation(cameraID: "fixture-built-in", sample: PostureSample(time: fixture.time, headHeight: 0.2, shoulderWidth: 0.5)))
    check(fixture.coach.status == status, "A late observation cannot revive paused monitoring")
    fixture.update(monitoring: false); fixture.time += 5; fixture.update(monitoring: false)
    check(fixture.captures.count == 1, "Saved calibration never overrides a Health reminder pause")
    fixture.update()
    check(fixture.captures.count == 2 && fixture.captures[1].starts == [false],
      "Resuming Health reminders starts ordinary monitoring from the saved calibration")
    if let view = fixture.window?.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
      view.cacheDisplay(in: view.bounds, to: rep)
      try rep.representation(using: .png, properties: [:])?.write(to: root.appendingPathComponent("posture-calibrated-active.png"))
    }
  }
  do {
    let fixture = PostureFixture(); defer { fixture.finish() }
    try fixture.open(monitoring: false); try fixture.click("Enable & Calibrate")
    let capture = fixture.captures[0]; fixture.samples(10, into: capture)
    check(capture.stops == 1 && PosturePreferences.load(fixture.defaults).baseline != nil,
      "Explicit calibration during a Health reminder pause saves its baseline and releases capture")
    fixture.update(monitoring: false)
    check(fixture.captures.count == 1, "Completing paused setup does not restart automatic capture")
    try fixture.calibrate()
    check(fixture.captures.count == 2 && fixture.captures[1].starts == [true],
      "A Health reminder pause still permits another explicitly requested calibration")
  }
  do {
    let fixture = PostureFixture(); defer { fixture.finish() }
    try fixture.open(); try fixture.click("Enable & Calibrate")
    let capture = fixture.captures[0]; fixture.samples(4, into: capture)
    fixture.update(monitoring: false)
    check(capture.stops == 0, "Pausing Health reminders during explicit calibration does not interrupt setup")
    fixture.samples(6, into: capture)
    check(capture.stops == 1 && PosturePreferences.load(fixture.defaults).baseline != nil,
      "Calibration finishing during Health reminder pause saves successfully and releases the camera")
  }
  do {
    let fixture = PostureFixture(); defer { fixture.finish() }
    try fixture.open(); try fixture.click("Enable & Calibrate")
    let capture = fixture.captures[0]; fixture.samples(10, into: capture)
    func hasNoticeTitle(_ view: NSView) -> Bool {
      if let label = view as? NSTextField, label.stringValue == "Take a moment to reset your position" { return true }
      return view.subviews.contains(where: hasNoticeTitle)
    }
    func notice() -> NSWindow? { NSApp.windows.first { $0.isVisible && $0.contentView.map(hasNoticeTitle) == true } }
    try fixture.click("Test Reminder")
    try fixture.click("Dismiss", in: postureNotice(titled: "Posture reminder preview"))
    let keyBefore = NSApp.keyWindow
    let deviationStarted = fixture.time + 3
    for offset in [0.0, 3, 6, 9, 9.99] {
      fixture.time = deviationStarted + offset
      capture.emit(.observation(cameraID: "fixture-built-in", sample: PostureSample(time: fixture.time, headHeight: 0.35, shoulderWidth: 0.5)))
    }
    check(notice() == nil && fixture.coach.status.contains("reminder in"),
      "A sustained lower position still shows its countdown at 9.99 seconds without an early reminder")
    fixture.time = deviationStarted + 10
    capture.emit(.observation(cameraID: "fixture-built-in", sample: PostureSample(time: fixture.time, headHeight: 0.35, shoulderWidth: 0.5)))
    let panel = notice()
    check(panel != nil, "Ten seconds of observed lower posture shows an actual reminder without any Pomodoro")
    check(panel?.styleMask.contains(.nonactivatingPanel) == true && panel?.isKeyWindow == false && NSApp.keyWindow === keyBefore,
      "The actual posture reminder preserves keyboard focus")
    fixture.update(monitoring: false)
    check(panel?.isVisible == false && capture.stops == 1, "Health pause hides an active posture notice and releases capture")
  }
  do {
    let fixture = PostureFixture(); defer { fixture.finish() }
    fixture.authorization = .notDetermined; try fixture.open()
    let before = PosturePreferences.load(fixture.defaults), summary = fixture.coach.calibrationSummary
    let keyBefore = NSApp.keyWindow
    try fixture.click("Test Reminder")
    let notice = postureNotice(titled: "Posture reminder preview")
    check(notice != nil && notice?.styleMask.contains(.nonactivatingPanel) == true
      && notice?.isKeyWindow == false && NSApp.keyWindow === keyBefore,
      "Test Reminder displays a distinct nonactivating preview while coaching is off")
    check(fixture.permissionRequests == 0 && fixture.captures.isEmpty && !fixture.coach.isEnabled
      && PosturePreferences.load(fixture.defaults) == before && fixture.coach.calibrationSummary == summary,
      "Test Reminder never requests permission, opens capture, enables coaching, or claims a calibration")
    try fixture.click("Snooze 5 min", in: notice)
    check(notice?.isVisible == false && fixture.captures.isEmpty && PosturePreferences.load(fixture.defaults) == before,
      "Snoozing the reminder preview only dismisses it and preserves posture preferences")
  }
  do {
    let fixture = PostureFixture(); defer { fixture.finish() }
    try fixture.open(); try fixture.calibrate()
    let capture = fixture.captures[0]; fixture.samples(4, into: capture)
    let before = PosturePreferences.load(fixture.defaults), summary = fixture.coach.calibrationSummary
    try fixture.click("Test Reminder")
    let notice = postureNotice(titled: "Posture reminder preview")
    check(notice != nil && fixture.captures.count == 1 && capture.stops == 0 && capture.modes.isEmpty
      && PosturePreferences.load(fixture.defaults) == before && fixture.coach.calibrationSummary == summary,
      "Testing a reminder during setup preserves the active calibration and its unsaved state")
    try fixture.click("Snooze 5 min", in: notice)
    fixture.samples(6, into: capture)
    check(PosturePreferences.load(fixture.defaults).baseline != nil && capture.stops == 0,
      "Snoozing the preview does not interrupt calibration or prevent immediate monitoring")
    let saved = PosturePreferences.load(fixture.defaults)
    try fixture.click("Test Reminder")
    try fixture.click("Snooze 5 min", in: postureNotice(titled: "Posture reminder preview"))
    fixture.update()
    check(capture.stops == 0 && fixture.captures.count == 1 && PosturePreferences.load(fixture.defaults) == saved,
      "Preview Snooze does not snooze genuine coaching or modify an existing calibration")
  }
  for cancellation in ["close", "timeout"] {
    let fixture = PostureFixture(); defer { fixture.finish() }
    let baseline = PostureBaseline(cameraID: "fixture-built-in", headHeight: 0.65, shoulderWidth: 0.45)
    PosturePreferences(enabled: true, baseline: baseline).save(fixture.defaults)
    try fixture.open()
    let original = fixture.captures[0]
    check(fixture.button("Recalibrate") != nil, "A saved, enabled baseline offers Recalibrate")
    try fixture.calibrate()
    let replacement = fixture.captures[1]; fixture.samples(3, into: replacement)
    check(original.stops == 1 && PosturePreferences.load(fixture.defaults).baseline == baseline,
      "Starting recalibration keeps the previous baseline until a replacement is saved")
    if cancellation == "close" { fixture.window?.close(); try fixture.open() }
    else { fixture.time += 31; fixture.update() }
    fixture.update()
    check(replacement.stops == 1 && PosturePreferences.load(fixture.defaults).baseline == baseline
      && fixture.captures.count == 3 && fixture.captures[2].starts == [false],
      "Recalibration (cancellation) keeps the old baseline and resumes eligible monitoring")
    let outcome = fixture.coach.calibrationSummary
    check(outcome.contains("Previous calibration kept") && fixture.containsLabel(outcome),
      "Recalibration (cancellation) displays a durable result separate from resumed monitoring")
    fixture.captures[2].emit(.ready(cameraID: "fixture-built-in", captureFPS: 5))
    fixture.time += 5; fixture.update()
    check(fixture.coach.calibrationSummary == outcome && fixture.containsLabel(outcome),
      "Live monitoring status cannot erase the previous-calibration result after (cancellation)")
    fixture.samples(10, into: replacement)
    check(PosturePreferences.load(fixture.defaults).baseline == baseline,
      "Late observations from the (cancellation) attempt cannot overwrite the kept baseline")
  }
  do {
    let fixture = PostureFixture(); defer { fixture.finish() }
    try fixture.open(); try fixture.calibrate()
    let capture = fixture.captures[0]; fixture.samples(4, into: capture)
    fixture.time += 0.5
    capture.emit(.trackingIssue("Move back so both shoulders are visible."))
    check(fixture.coach.status.contains("Move back so both shoulders are visible.")
      && fixture.coach.status.contains("4/10") && PosturePreferences.load(fixture.defaults).baseline == nil,
      "Brief tracking loss provides concrete guidance while retaining recent useful sample progress")
    fixture.samples(6, into: capture)
    check(PosturePreferences.load(fixture.defaults).baseline != nil && capture.stops == 0,
      "Calibration can finish after a brief dropout without starting ten samples over")
  }
  do {
    let fixture = PostureFixture(); defer { fixture.finish() }
    try fixture.open(); try fixture.calibrate()
    let capture = fixture.captures[0]
    for index in 0..<10 {
      fixture.time += 0.5
      capture.emit(.observation(cameraID: "fixture-built-in", sample: PostureSample(time: fixture.time,
        headHeight: index.isMultiple(of: 2) ? 0.3 : 0.8, shoulderWidth: 0.5)))
    }
    check(PosturePreferences.load(fixture.defaults).baseline == nil && capture.modes.isEmpty
      && fixture.coach.status.contains("Checking stability") && fixture.coach.calibrationSummary.contains("not saved yet"),
      "Ten inconsistent observations do not falsely report completion before a baseline is saved")
    fixture.time += 31; fixture.update()
    let outcome = fixture.coach.calibrationSummary
    check(capture.stops == 1 && outcome.contains("Calibration not saved") && fixture.containsLabel(outcome),
      "Unsteady calibration ends with a visible failure instead of leaving an endless ten-sample status")
    fixture.time += 5; fixture.update(); fixture.update(monitoring: false); fixture.update()
    check(fixture.coach.calibrationSummary == outcome && fixture.containsLabel(outcome)
      && fixture.captures.count == 1 && PosturePreferences.load(fixture.defaults).baseline == nil,
      "A failed first calibration stays explained after ordinary updates and never starts monitoring")
    try fixture.calibrate()
    check(fixture.coach.calibrationSummary.contains("not saved yet") && fixture.captures.count == 2,
      "An explicit retry replaces the failed result with an honest unsaved progress state")
    fixture.samples(10, into: fixture.captures[1])
    check(fixture.coach.calibrationSummary == "Calibration saved"
      && PosturePreferences.load(fixture.defaults).baseline != nil && fixture.captures[1].stops == 0,
      "A stable retry saves a working baseline and replaces the previous failure result")
  }
  do {
    let fixture = PostureFixture(); defer { fixture.finish() }
    try fixture.open(); try fixture.calibrate()
    let capture = fixture.captures[0]; fixture.samples(4, into: capture)
    for _ in 0..<6 {
      fixture.time += 5
      capture.emit(.trackingIssue("Both shoulders are not visible."))
    }
    check(capture.stops == 1 && fixture.captures.count == 1 && PosturePreferences.load(fixture.defaults).baseline == nil
      && fixture.coach.calibrationSummary.contains("Calibration not saved")
      && fixture.coach.calibrationSummary.contains("Both shoulders are not visible."),
      "Repeated tracking failures preserve an actionable reason and cannot extend the calibration deadline")
  }
  for cancellation in ["close", "unsafe", "disable", "shutdown"] {
    let fixture = PostureFixture(); defer { fixture.finish() }
    fixture.authorization = .notDetermined; try fixture.open(); try fixture.click("Enable & Calibrate")
    check(fixture.permissionRequests == 1 && fixture.captures.isEmpty,
      "Explicit setup requests permission before creating any capture")
    switch cancellation {
    case "close": fixture.window?.close()
    case "unsafe": fixture.update(allowed: false); fixture.update(allowed: true)
    case "disable": try fixture.click("Turn Off")
    default: fixture.coach.shutdown()
    }
    try await fixture.grantPermission()
    check(fixture.captures.isEmpty && PosturePreferences.load(fixture.defaults).baseline == nil,
      "A permission grant after \(cancellation) cannot resurrect cancelled calibration")
  }
  do {
    let fixture = PostureFixture(); defer { fixture.finish() }
    fixture.authorization = .notDetermined; try fixture.open(); try fixture.click("Enable & Calibrate")
    fixture.update(); try fixture.click("Enable & Calibrate")
    check(fixture.permissionRequests == 1 && fixture.captures.isEmpty,
      "Safe no-focus updates and repeated setup clicks preserve one pending permission request")
    try await fixture.grantPermission()
    check(fixture.captures.count == 1 && fixture.captures[0].starts == [true],
      "A current explicit permission grant starts calibration without requiring focus")
  }
  do {
    let fixture = PostureFixture(); defer { fixture.finish() }
    try fixture.open(); fixture.update(idle: 120); try fixture.click("Enable & Calibrate")
    check(fixture.captures.count == 1,
      "Pressing Enable & Calibrate counts as fresh activity despite an older idle sample")
  }
  do {
    let fixture = PostureFixture(); defer { fixture.finish() }
    fixture.authorization = .notDetermined; try fixture.open(); fixture.update(allowed: false)
    try fixture.click("Enable & Calibrate")
    check(fixture.captures.isEmpty && fixture.permissionRequests == 0,
      "A setup button cannot override locked or sleeping system state")
  }
  for cancellation in ["idle", "locked", "close", "timeout"] {
    let fixture = PostureFixture(); defer { fixture.finish() }
    try fixture.open(); try fixture.click("Enable & Calibrate")
    let capture = fixture.captures[0]
    switch cancellation {
    case "idle": fixture.update(idle: 120)
    case "locked": fixture.update(allowed: false)
    case "close": fixture.window?.close()
    default: fixture.time += 31; fixture.update()
    }
    check(capture.stops == 1, "Standalone calibration releases capture after \(cancellation), even without camera callbacks")
    fixture.samples(10, into: capture)
    check(PosturePreferences.load(fixture.defaults).baseline == nil,
      "Late fake-camera samples after \(cancellation) cannot save a cancelled calibration")
  }
}
