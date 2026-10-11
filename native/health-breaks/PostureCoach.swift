import AppKit
import AVFoundation
import Darwin

@MainActor final class PostureCoach: NSObject, NSWindowDelegate {
  private let defaults: UserDefaults
  private let onChange: () -> Void
  private let authorizationStatus: () -> AVAuthorizationStatus
  private let requestCameraAccess: (@escaping @Sendable (Bool) -> Void) -> Void
  private let makeCapture: (@escaping @MainActor (PostureCaptureEngine.Event) -> Void) -> any PostureCapturing
  private let now: () -> TimeInterval
  private var preferences: PosturePreferences
  private var eligibility = PostureEligibility()
  private var detector = PostureDriftDetector()
  private var calibration: PostureCalibration?
  private var capture: (any PostureCapturing)?
  private var lifetime = PostureWorkGate()
  private var permissionPending = false
  private var calibrationRequested = false
  private var calibrationOutcome: String?
  private var lastTrackingGuidance: String?
  private var cameraID: String?
  private var pausedForBudget = false, memoryPressure = false
  private var budget = PosturePerformanceBudget()
  private var measureOrigin: PostureProcessSample?, measureWindow: PostureProcessSample?
  private var pressureSource: DispatchSourceMemoryPressure?
  private var window: NSWindow?, statusLabel: NSTextField?, calibrationLabel: NSTextField?
  private var calibrateButton: NSButton?
  private var previewButton: NSButton?, previewView: NSView?, previewLayer: AVCaptureVideoPreviewLayer?
  private var notice: PostureNotice?
  private(set) var status = "Posture coaching is off"
  var isEnabled: Bool { preferences.enabled }
  /// A calibration or an open Posture Coach window that an installer restart would interrupt.
  var isBusy: Bool { calibrationRequested || permissionPending || window?.isVisible == true }
  var calibrationSummary: String {
    if calibrationRequested { return "Calibration in progress · not saved yet" }
    if let calibrationOutcome { return calibrationOutcome }
    return preferences.baseline?.isValid == true ? "Calibration saved" : "Not calibrated · reminders cannot start yet"
  }

  init(defaults: UserDefaults = .standard,
    authorizationStatus: @escaping () -> AVAuthorizationStatus = { AVCaptureDevice.authorizationStatus(for: .video) },
    requestCameraAccess: @escaping (@escaping @Sendable (Bool) -> Void) -> Void = { AVCaptureDevice.requestAccess(for: .video, completionHandler: $0) },
    makeCapture: @escaping (@escaping @MainActor (PostureCaptureEngine.Event) -> Void) -> any PostureCapturing = { PostureCaptureEngine(deliver: $0) },
    now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
    onChange: @escaping () -> Void = {}) {
    self.defaults = defaults; self.onChange = onChange
    self.authorizationStatus = authorizationStatus; self.requestCameraAccess = requestCameraAccess
    self.makeCapture = makeCapture; self.now = now
    preferences = PosturePreferences.load(defaults)
    super.init()
    if preferences.enabled { status = preferences.baseline == nil ? "Choose Enable & Calibrate to set up posture coaching" : "Calibrated · ready while you work" }
    let pressure = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: .main)
    pressure.setEventHandler { [weak self] in
      MainActor.assumeIsolated {
        guard let self, let pressure = self.pressureSource else { return }
        self.memoryPressure = !pressure.data.contains(.normal); self.reconcile()
      }
    }
    pressure.resume(); pressureSource = pressure
  }
  deinit { pressureSource?.cancel() }
  func update(idleSeconds: TimeInterval, systemAllowed: Bool, monitoringAllowed: Bool = true) {
    eligibility = PostureEligibility(monitoringAllowed: monitoringAllowed, idleSeconds: idleSeconds, systemAllowed: systemAllowed)
    reconcile(); checkBudget()
  }
  func shutdown() { stopCapture(); notice?.hide(); pressureSource?.cancel(); pressureSource = nil }
  func snooze() {
    detector.snooze(at: now()); notice?.hide(); reconcile()
  }
  private func setStatus(_ value: String) {
    calibrationLabel?.stringValue = calibrationSummary
    calibrateButton?.title = preferences.enabled && preferences.baseline?.isValid == true ? "Recalibrate" : "Enable & Calibrate"
    guard value != status else { return }
    status = value; statusLabel?.stringValue = value; onChange()
  }
  private func stopCapture() {
    lifetime.stop(); capture?.stop(); capture = nil
    calibration = nil; calibrationRequested = false; cameraID = nil; detector.interrupt()
    previewLayer?.session = nil; previewView?.isHidden = true
    measureWindow = nil
  }
  private func stopCalibration(_ reason: String) {
    stopCapture()
    calibrationOutcome = preferences.baseline?.isValid == true
      ? "Previous calibration kept · \(reason)" : "Calibration not saved · \(reason)"
    setStatus(calibrationSummary)
    // A failed retry must not delete a working calibration or silently disable coaching.
    reconcile()
  }
  private func reconcile() {
    let now = now()
    guard preferences.enabled else { stopCapture(); setStatus("Posture coaching is off"); return }
    guard eligibility.permitsCalibration else {
      if capture != nil || calibrationRequested { stopCapture() }
      notice?.hide()
      setStatus("Posture paused while you are away")
      return
    }
    guard !pausedForBudget else { setStatus("Posture paused to keep your Mac responsive. Recalibrate to retry."); return }
    guard !memoryPressure && ProcessInfo.processInfo.thermalState != .serious && ProcessInfo.processInfo.thermalState != .critical else {
      if capture != nil || calibrationRequested { stopCapture() }
      setStatus("Posture paused while your Mac is under load"); return
    }
    // Explicit setup is independent of the timer, including while waiting for permission.
    // The deadline also handles a camera that never delivers an observation.
    if calibrationRequested {
      if let calibration, now - calibration.started >= 30 {
        stopCalibration(lastTrackingGuidance ?? "Setup timed out. Adjust framing and try again.")
      }
      return
    }
    guard eligibility.permitsCamera else {
      if capture != nil { stopCapture() }
      notice?.hide()
      setStatus(preferences.baseline == nil ? "Choose Enable & Calibrate to set up posture coaching" : "Calibrated · paused with Health Breaks reminders")
      return
    }
    guard now >= detector.snoozedUntil else {
      if capture != nil { stopCapture() }
      setStatus("Posture reminders snoozed for five minutes"); return
    }
    if capture != nil { return }
    guard preferences.baseline?.isValid == true else { setStatus(calibrationOutcome ?? "Choose Enable & Calibrate to set up posture coaching"); return }
    // A remembered opt-in may resume capture, but never shows a new privacy prompt itself.
    guard authorizationStatus() == .authorized else {
      setStatus("Camera permission is needed. Choose Enable & Calibrate."); return
    }
    beginCapture(calibrating: false)
  }
  private func beginCapture(calibrating: Bool) {
    guard (calibrating ? eligibility.permitsCalibration : eligibility.permitsCamera), preferences.enabled, !memoryPressure, !pausedForBudget,
      ProcessInfo.processInfo.thermalState != .serious, ProcessInfo.processInfo.thermalState != .critical else { return }
    stopCapture()
    let token = lifetime.start()
    budget = PosturePerformanceBudget()
    // Keep the first pre-capture footprint for this process lifetime: model caches surviving
    // pause/resume must never raise the baseline and conceal the coaching memory cost.
    if measureOrigin == nil { measureOrigin = PostureProcessSample.read() }
    measureWindow = PostureProcessSample.read()
    calibrationRequested = calibrating
    if calibrating { calibration = PostureCalibration(started: now()) }
    let engine = makeCapture { [weak self] event in
      guard let self, self.lifetime.isCurrent(token), self.preferences.enabled,
        (self.calibrationRequested ? self.eligibility.permitsCalibration : self.eligibility.permitsCamera) else { return }
      self.receive(event)
    }
    capture = engine; updatePreview()
    setStatus(calibrating ? "Sit comfortably with your face and both shoulders visible…" : "Starting local posture monitoring…")
    // Status updates may synchronously refresh activity and cancel this session.
    guard lifetime.isCurrent(token), capture === engine else { return }
    engine.start(calibrating: calibrating)
  }
  private func receive(_ event: PostureCaptureEngine.Event) {
    let now = now()
    switch event {
    case .ready(let id, let fps):
      cameraID = id
      if calibration == nil, preferences.baseline?.cameraID != id {
        stopCapture(); preferences.baseline = nil; preferences.save(defaults)
        calibrationOutcome = "Calibration not saved · the built-in camera changed"
        setStatus("The built-in camera changed. Calibrate again.")
      } else if calibration == nil {
        setStatus("Posture active · checks every \(budget.slowed ? 5 : 3)s · camera \(Int(fps.rounded())) fps")
      }
    case .unavailable(let reason):
      detector.interrupt()
      if let previous = calibration { calibration = PostureCalibration(started: previous.started) }
      lastTrackingGuidance = reason
      setStatus(reason)
    case .trackingIssue(let reason):
      lastTrackingGuidance = reason
      if var collecting = calibration {
        guard now - collecting.started <= 30 else { stopCalibration(reason); return }
        collecting.observe(nil, at: now); calibration = collecting
        let progress = collecting.samples.count < 10
          ? "Calibrating · \(collecting.samples.count)/10 usable samples" : "Checking stability"
        setStatus("\(progress) · \(reason)")
      } else { detector.interrupt(); setStatus(reason) }
      checkBudget()
    case .observation(let id, let sample):
      if var collecting = calibration {
        guard now - collecting.started <= 30 else {
          stopCalibration(lastTrackingGuidance ?? "Setup timed out. Adjust framing and try again."); return
        }
        collecting.observe(sample, at: now); calibration = collecting
        if sample != nil, let baseline = collecting.baseline(cameraID: id, now: now) {
          preferences.baseline = baseline; preferences.save(defaults); calibration = nil; calibrationRequested = false
          calibrationOutcome = "Calibration saved"; lastTrackingGuidance = nil
          detector = PostureDriftDetector()
          if eligibility.permitsCamera {
            capture?.setMode(calibrating: false, slow: false)
            updatePreview(); setStatus("Calibrated · posture checks every 3s while you work")
          } else {
            stopCapture(); setStatus("Calibrated · paused with Health Breaks reminders")
          }
        } else if collecting.samples.count == 10 {
          setStatus("Checking stability · hold your comfortable position")
        } else { setStatus("Calibrating · \(collecting.samples.count)/10 usable samples · keep face and shoulders visible") }
      } else if let baseline = preferences.baseline, baseline.cameraID == id {
        if let sample, sample.isValid, abs(now - sample.time) <= 2 {
          let ratio = sample.shoulderWidth / baseline.shoulderWidth
          if !(0.75...1.25).contains(ratio) {
            detector.interrupt(); setStatus("Your framing changed. Recalibrate if you moved the screen or seat."); return
          }
        }
        let shouldNudge = detector.observe(sample, baseline: baseline, at: now)
        if let sample, sample.isValid, abs(now - sample.time) <= 2 {
          if let badSince = detector.badSince {
            if detector.latched {
              setStatus("Reminder shown · return to a comfortable position")
            } else if let lastNudge = detector.lastNudge, now - lastNudge < 300 {
              setStatus("Position is lower · reminders are cooling down")
            } else {
              let remaining = Int(ceil(max(0, PostureDriftDetector.requiredDeviationDuration - (now - badSince))))
              setStatus("Position is lower · reminder in \(remaining)s if it continues")
            }
          } else { setStatus("Posture active · position close to your calibration") }
        } else { setStatus("Posture waiting for a clear face and both shoulders") }
        if shouldNudge && eligibility.permitsCamera && capture != nil && preferences.enabled {
          if notice == nil { notice = PostureNotice(snooze: { [weak self] in self?.snooze() }) }
          notice?.show()
        }
      }
      checkBudget()
    }
  }
  private func checkBudget() {
    guard capture != nil, calibration == nil, let origin = measureOrigin,
      let previous = measureWindow, let current = PostureProcessSample.read(), current.time - previous.time >= 30 else { return }
    let cpu = Double(current.cpuNanoseconds >= previous.cpuNanoseconds ? current.cpuNanoseconds - previous.cpuNanoseconds : 0)
      / 1_000_000_000 / (current.time - previous.time)
    let extra = current.footprint > origin.footprint ? current.footprint - origin.footprint : 0
    measureWindow = current
    switch budget.evaluate(cpuFraction: cpu, additionalFootprint: extra) {
    case .continueMonitoring: break
    case .slowDown:
      capture?.setMode(calibrating: false, slow: true)
      setStatus("Posture reduced to one check every 5s to save resources")
    case .pause:
      pausedForBudget = true; stopCapture(); notice?.hide()
      setStatus("Posture paused to keep your Mac responsive. Recalibrate to retry.")
    }
  }
  @objc private func enableAndCalibrate() {
    guard !permissionPending else { return }
    preferences.enabled = true; preferences.save(defaults)
    calibrationOutcome = nil; lastTrackingGuidance = nil
    pausedForBudget = false; detector = PostureDriftDetector(); stopCapture(); notice?.hide()
    // Pressing this button is fresh activity even if the last periodic idle sample is stale.
    eligibility.idleSeconds = 0
    guard eligibility.permitsCalibration else { stopCalibration("Try again when your Mac is awake and unlocked."); return }
    guard !memoryPressure, ProcessInfo.processInfo.thermalState != .serious, ProcessInfo.processInfo.thermalState != .critical else {
      stopCalibration("Wait until your Mac is under less load."); return
    }
    switch authorizationStatus() {
    case .authorized: beginCapture(calibrating: true)
    case .notDetermined:
      permissionPending = true; calibrationRequested = true
      let permissionToken = lifetime.start()
      setStatus("Allow the built-in camera in the macOS permission prompt")
      requestCameraAccess { [weak self] granted in
        Task { @MainActor in
          guard let self else { return }; self.permissionPending = false
          guard self.preferences.enabled, self.calibrationRequested, self.lifetime.isCurrent(permissionToken) else { return }
          if granted { self.reconcile(); if self.calibrationRequested { self.beginCapture(calibrating: true) } }
          else { self.stopCalibration("Camera access denied. Allow Health Breaks in System Settings → Privacy & Security → Camera.") }
        }
      }
    default: stopCalibration("Camera access denied. Allow Health Breaks in System Settings → Privacy & Security → Camera.")
    }
  }
  @objc private func disable() {
    preferences.enabled = false; preferences.save(defaults); stopCapture(); notice?.hide(); setStatus("Posture coaching is off")
  }
  @objc private func testReminder() {
    guard eligibility.systemAllowed else { return }
    if notice == nil { notice = PostureNotice(snooze: { [weak self] in self?.snooze() }) }
    notice?.show(preview: true)
  }
  @objc private func previewChanged() { updatePreview() }
  private func updatePreview() {
    let visible = calibration != nil && capture != nil && window?.isVisible == true && previewButton?.state == .on
    previewView?.isHidden = !visible
    previewLayer?.session = visible ? capture?.session : nil
  }
  func showSettings() {
    if window == nil {
      let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 640), styleMask: [.titled, .closable], backing: .buffered, defer: false)
      panel.title = "Posture Coach"; panel.isReleasedWhenClosed = false; panel.delegate = self
      let root = NSView(frame: panel.contentView!.bounds); panel.contentView = root
      func label(_ text: String, _ y: CGFloat, _ height: CGFloat, size: CGFloat = 13) -> NSTextField {
        let value = NSTextField(wrappingLabelWithString: text)
        value.frame = NSRect(x: 22, y: y, width: 516, height: height); value.font = .systemFont(ofSize: size)
        root.addSubview(value); return value
      }
      _ = label("Gentle posture reminders while you work", 598, 24, size: 16)
      _ = label("Uses only your MacBook’s built-in camera. Frames stay in memory and are never recorded or uploaded. Checks work independently of Pomodoro and pause when you are idle, locked, or asleep.", 521, 66)
      _ = label("Sit comfortably with your face and both shoulders in the preview. Setup needs about five seconds of clear, steady tracking. Wait for ‘Calibration saved’ before closing. No Pomodoro needed.", 448, 62)
      let calibrate = NSButton(title: "Enable & Calibrate", target: self, action: #selector(enableAndCalibrate))
      calibrate.frame = NSRect(x: 20, y: 402, width: 200, height: 32); calibrate.bezelStyle = .rounded; root.addSubview(calibrate); calibrateButton = calibrate
      let disable = NSButton(title: "Turn Off", target: self, action: #selector(disable))
      disable.frame = NSRect(x: 225, y: 402, width: 110, height: 32); disable.bezelStyle = .rounded; root.addSubview(disable)
      let test = NSButton(title: "Test Reminder", target: self, action: #selector(testReminder))
      test.frame = NSRect(x: 340, y: 402, width: 200, height: 32); test.bezelStyle = .rounded; root.addSubview(test)
      calibrationLabel = label(calibrationSummary, 353, 42); calibrationLabel?.font = .systemFont(ofSize: 13, weight: .semibold)
      let preview = NSButton(checkboxWithTitle: "Show camera preview during calibration", target: self, action: #selector(previewChanged))
      preview.frame = NSRect(x: 22, y: 275, width: 516, height: 25); preview.state = .on; root.addSubview(preview); previewButton = preview
      statusLabel = label(status, 302, 48); statusLabel?.textColor = .secondaryLabelColor
      let previewArea = NSView(frame: NSRect(x: 120, y: 14, width: 320, height: 240)); previewArea.wantsLayer = true
      let layer = AVCaptureVideoPreviewLayer(); layer.frame = previewArea.bounds; layer.videoGravity = .resizeAspect
      previewArea.layer?.addSublayer(layer); root.addSubview(previewArea); previewArea.isHidden = true
      previewView = previewArea; previewLayer = layer; window = panel
    }
    setStatus(status); statusLabel?.stringValue = status; window?.center(); window?.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true); updatePreview()
  }
  func windowWillClose(_ notification: Notification) {
    previewLayer?.session = nil; previewView?.isHidden = true
    if calibrationRequested { stopCalibration("Setup cancelled.") }
  }
}

private struct PostureProcessSample {
  let time: TimeInterval, cpuNanoseconds: UInt64, footprint: UInt64
  static func read() -> PostureProcessSample? {
    var info = rusage_info_v2()
    let status = withUnsafeMutablePointer(to: &info) { pointer in
      pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_V2, $0) }
    }
    guard status == 0 else { return nil }
    return Self(time: ProcessInfo.processInfo.systemUptime, cpuNanoseconds: info.ri_user_time + info.ri_system_time, footprint: info.ri_phys_footprint)
  }
}

@MainActor private final class PostureNotice: NSWindowController {
  private var expiration: Timer?
  private let snoozeAction: () -> Void
  private var titleLabel: NSTextField?, detailLabel: NSTextField?
  private var previewMode = false
  init(snooze: @escaping () -> Void) {
    snoozeAction = snooze
    let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 148), styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
    panel.level = .floating; panel.hidesOnDeactivate = false; panel.isReleasedWhenClosed = false
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    super.init(window: panel)
    let root = NSVisualEffectView(frame: panel.contentView!.bounds)
    root.material = .hudWindow; root.state = .active; root.wantsLayer = true; root.layer?.cornerRadius = 16
    panel.contentView = root
    let title = NSTextField(labelWithString: "Take a moment to reset your position")
    titleLabel = title
    title.font = .systemFont(ofSize: 14, weight: .semibold); title.frame = NSRect(x: 18, y: 107, width: 328, height: 23); root.addSubview(title)
    let detail = NSTextField(wrappingLabelWithString: "Your head has stayed lower than your calibrated position. Shift to a position that feels comfortable.")
    detailLabel = detail
    detail.frame = NSRect(x: 18, y: 48, width: 324, height: 54); root.addSubview(detail)
    let done = NSButton(title: "Dismiss", target: self, action: #selector(dismiss))
    done.frame = NSRect(x: 18, y: 10, width: 110, height: 30); done.bezelStyle = .rounded; root.addSubview(done)
    let later = NSButton(title: "Snooze 5 min", target: self, action: #selector(PostureNotice.snooze))
    later.frame = NSRect(x: 155, y: 10, width: 180, height: 30); later.bezelStyle = .rounded; root.addSubview(later)
  }
  required init?(coder: NSCoder) { fatalError() }
  func show(preview: Bool = false) {
    previewMode = preview
    titleLabel?.stringValue = preview ? "Posture reminder preview" : "Take a moment to reset your position"
    detailLabel?.stringValue = preview ? "This is a test. Real reminders appear after \(Int(PostureDriftDetector.requiredDeviationDuration)) seconds of sustained change from your calibrated position." : "Your head has stayed lower than your calibrated position. Shift to a position that feels comfortable."
    guard let panel = window, let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main else { return }
    panel.setFrameOrigin(NSPoint(x: screen.visibleFrame.maxX - panel.frame.width - 20, y: screen.visibleFrame.maxY - panel.frame.height - 20))
    panel.orderFrontRegardless(); expiration?.invalidate()
    expiration = Timer.scheduledTimer(withTimeInterval: 20, repeats: false) { [weak self] _ in MainActor.assumeIsolated { self?.hide() } }
  }
  func hide() { expiration?.invalidate(); expiration = nil; window?.orderOut(nil) }
  @objc private func dismiss() { hide() }
  @objc private func snooze() { hide(); if !previewMode { snoozeAction() } }
}
