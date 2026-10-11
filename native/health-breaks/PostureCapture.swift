import AppKit
import AVFoundation
import Vision
import CoreMedia

protocol PostureCapturing: AnyObject {
  var session: AVCaptureSession { get }
  func start(calibrating: Bool)
  func setMode(calibrating: Bool, slow: Bool)
  func stop()
}

/// Created only after authorization, for explicit calibration or opted-in active-use monitoring.
final class PostureCaptureEngine: NSObject, PostureCapturing, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
  enum Event {
    case ready(cameraID: String, captureFPS: Double)
    case observation(cameraID: String, sample: PostureSample?)
    case trackingIssue(String)
    case unavailable(String)
  }
  let session = AVCaptureSession()
  // A rapid recalibration must finish releasing the previous session before opening another.
  private static let workQueue = DispatchQueue(label: "com.productivity-os.posture.capture", qos: .utility)
  private let queue = PostureCaptureEngine.workQueue
  private let deliver: @MainActor (Event) -> Void
  private var device: AVCaptureDevice?
  private var observations: [NSKeyValueObservation] = []
  private var notifications: [NSObjectProtocol] = []
  private var request: VNDetectHumanBodyPoseRequest?
  private var wanted = false, calibrating = false, slow = false, interrupted = false
  private var frameGate = PostureWorkGate()
  private var captureFPS = 0.0
  private var prepared = false
  // Intent changes synchronously; AVFoundation work stays on the utility queue.
  // This lock is never held while configuring, starting, stopping, or processing a frame.
  private let intentLock = NSLock()
  private var desired = false
  private var intentGeneration: UInt64 = 0
  private var activeGeneration: UInt64 = 0
  private func setDesired(_ value: Bool) -> UInt64 {
    intentLock.lock(); defer { intentLock.unlock() }
    intentGeneration &+= 1; desired = value; return intentGeneration
  }
  private func isDesired(_ generation: UInt64) -> Bool {
    intentLock.lock(); defer { intentLock.unlock() }
    return desired && intentGeneration == generation
  }
  init(deliver: @escaping @MainActor (Event) -> Void) { self.deliver = deliver; super.init() }
  private func emit(_ event: Event) { let callback = deliver; Task { @MainActor in callback(event) } }
  func start(calibrating: Bool) {
    let generation = setDesired(true)
    queue.async { [self] in
      guard isDesired(generation) else { return }
      activeGeneration = generation
      wanted = true; self.calibrating = calibrating; frameGate.start()
      do { try configure(); reconcile() }
      catch { emit(.unavailable("Camera unavailable: \(error.localizedDescription)")) }
    }
  }
  func setMode(calibrating: Bool, slow: Bool) {
    queue.async { [self] in
      let changed = self.calibrating != calibrating
      self.calibrating = calibrating; self.slow = slow; frameGate.resetSchedule()
      // Leaving calibration drops a prepared, current session to its slowest rate.
      if changed, wanted, prepared, isDesired(activeGeneration), let device { try? applyFrameRate(device) }
    }
  }
  func stop() {
    _ = setDesired(false)
    queue.async { [self] in
      wanted = false; frameGate.stop()
      if session.isRunning { session.stopRunning() }
      observations.removeAll()
      for token in notifications { NotificationCenter.default.removeObserver(token) }
      notifications.removeAll(); request = nil
      session.beginConfiguration()
      for input in session.inputs { session.removeInput(input) }
      for output in session.outputs { session.removeOutput(output) }
      session.commitConfiguration(); device = nil; prepared = false
    }
  }
  private func configure() throws {
    guard isDesired(activeGeneration) else { return }
    guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else { throw PostureCaptureError("Camera permission is not granted.") }
    let discovery = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera], mediaType: .video, position: .unspecified)
    let builtIn = discovery.devices.filter { $0.deviceType == .builtInWideAngleCamera && !$0.isContinuityCamera && $0.isConnected }
    guard builtIn.count == 1, let device = builtIn.first else { throw PostureCaptureError("The built-in MacBook camera is unavailable. No other camera will be used.") }
    self.device = device
    func watch(_ keyPath: KeyPath<AVCaptureDevice, Bool>) {
      observations.append(device.observe(keyPath, options: [.new]) { [weak self] _, _ in
        guard let self else { return }; self.queue.async { self.reconcile() }
      })
    }
    watch(\.isInUseByAnotherApplication); watch(\.isSuspended); watch(\.isConnected)
    let center = NotificationCenter.default
    notifications.append(center.addObserver(forName: AVCaptureSession.wasInterruptedNotification, object: session, queue: nil) { [weak self] _ in
      guard let self else { return }; self.queue.async { self.interrupted = true; self.reconcile() }
    })
    notifications.append(center.addObserver(forName: AVCaptureSession.interruptionEndedNotification, object: session, queue: nil) { [weak self] _ in
      guard let self else { return }; self.queue.async { self.interrupted = false; self.reconcile() }
    })
    notifications.append(center.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil) { [weak self] _ in
      guard let self else { return }; self.queue.async {
        self.wanted = false
        if self.session.isRunning { self.session.stopRunning() }
        self.emit(.unavailable("Camera paused after a capture error. Recalibrate to retry."))
      }
    })
    // Do not construct an input while another application is using the camera.
    if device.isInUseByAnotherApplication || device.isSuspended { return }
    try prepareSession(device)
  }
  private func prepareSession(_ device: AVCaptureDevice) throws {
    guard isDesired(activeGeneration), !prepared else { return }
    let input = try AVCaptureDeviceInput(device: device), output = AVCaptureVideoDataOutput()
    session.beginConfiguration()
    var configurationOpen = true
    defer {
      if configurationOpen { session.commitConfiguration() }
      if !prepared {
        session.beginConfiguration()
        for input in session.inputs { session.removeInput(input) }
        for output in session.outputs { session.removeOutput(output) }
        session.commitConfiguration()
      }
    }
    guard session.canSetSessionPreset(.vga640x480) else { throw PostureCaptureError("This camera has no supported 640×480 capture mode.") }
    session.sessionPreset = .vga640x480
    guard session.canAddInput(input), session.canAddOutput(output) else { throw PostureCaptureError("Camera input could not be configured.") }
    session.addInput(input)
    output.alwaysDiscardsLateVideoFrames = true
    output.setSampleBufferDelegate(self, queue: queue); session.addOutput(output)
    session.commitConfiguration(); configurationOpen = false
    // Read supported formats and rates only after the requested session preset takes effect.
    let formats = output.availableVideoPixelFormatTypes
    guard let pixelFormat = [kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
      kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_32BGRA].first(where: { formats.contains($0) })
      else { throw PostureCaptureError("The camera has no supported pixel format.") }
    output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: pixelFormat]
    if let connection = output.connection(with: .video), connection.isVideoMirroringSupported {
      connection.automaticallyAdjustsVideoMirroring = false; connection.isVideoMirrored = false
    }
    try applyFrameRate(device)
    prepared = true
  }
  /// 5 fps while calibrating; otherwise the slowest supported rate (see `PostureFrameRate`).
  private func applyFrameRate(_ device: AVCaptureDevice) throws {
    let ranges = device.activeFormat.videoSupportedFrameRateRanges
    guard let fps = PostureFrameRate.choose(ranges.map { (min: $0.minFrameRate, max: $0.maxFrameRate) }, calibrating: calibrating),
      let range = ranges.first(where: { $0.minFrameRate <= fps && fps <= $0.maxFrameRate }) else { throw PostureCaptureError("Camera frame rates are unavailable.") }
    // Range endpoints use the device's exact durations; a rounded 1/fps could fall outside the range.
    let duration = fps == range.minFrameRate ? range.maxFrameDuration : fps == range.maxFrameRate ? range.minFrameDuration
      : fps == fps.rounded() ? CMTime(value: 1, timescale: CMTimeScale(fps)) : CMTime(seconds: 1 / fps, preferredTimescale: 60_000)
    try device.lockForConfiguration()
    defer { device.unlockForConfiguration() }
    // Keep min ≤ max at every step: when slowing down, lengthen the maximum duration first.
    if CMTimeCompare(duration, device.activeVideoMaxFrameDuration) > 0 { device.activeVideoMaxFrameDuration = duration; device.activeVideoMinFrameDuration = duration }
    else { device.activeVideoMinFrameDuration = duration; device.activeVideoMaxFrameDuration = duration }
    captureFPS = fps
  }
  private func reconcile() {
    guard wanted, isDesired(activeGeneration), let device else { return }
    let problem: String?
    if !device.isConnected { problem = "Built-in camera disconnected. Recalibrate when it is available." }
    else if device.isSuspended { problem = "Posture paused while the built-in camera is unavailable." }
    else if device.isInUseByAnotherApplication { problem = "Posture paused: another app is using the camera." }
    else if interrupted { problem = "Posture paused while camera capture is interrupted." }
    else { problem = nil }
    if let problem {
      if session.isRunning { session.stopRunning() }
      frameGate.resetSchedule(); emit(.unavailable(problem)); return
    }
    do {
      try prepareSession(device)
      if !session.isRunning {
        request = VNDetectHumanBodyPoseRequest()
        // Cancellation before this point must not activate a queued session. A call
        // already executing cannot be interrupted; the queued stop releases it next.
        guard isDesired(activeGeneration) else { return }
        session.startRunning()
        guard session.isRunning else { throw PostureCaptureError("The camera could not start.") }
        // Reassert the chosen rate in case starting the session restored the preset's default.
        try? applyFrameRate(device)
      }
      emit(.ready(cameraID: device.uniqueID, captureFPS: captureFPS))
    } catch { emit(.unavailable("Camera unavailable: \(error.localizedDescription)")) }
  }
  func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
    guard wanted, isDesired(activeGeneration), session.isRunning, let device else { return }
    let now = ProcessInfo.processInfo.systemUptime
    let interval = calibrating ? 0.5 : (slow ? 5.0 : 3.0)
    guard let token = frameGate.begin(at: now, interval: interval) else { return }
    defer { frameGate.finish(token) }
    autoreleasepool {
      guard isDesired(activeGeneration) else { return }
      guard let pixels = CMSampleBufferGetImageBuffer(sampleBuffer), let request else {
        emit(.trackingIssue("The camera frame is not ready. Wait a moment, then try Enable & Calibrate again.")); return
      }
      do {
        try VNImageRequestHandler(cvPixelBuffer: pixels, orientation: .up, options: [:]).perform([request])
        guard ProcessInfo.processInfo.systemUptime - now <= 2 else {
          emit(.trackingIssue("Camera analysis is taking too long. Let your Mac settle, then try Enable & Calibrate again.")); return
        }
        let poses = request.results ?? []
        let width = Double(CVPixelBufferGetWidth(pixels)), height = Double(CVPixelBufferGetHeight(pixels))
        var landmarks: [PostureJoint: PostureLandmark] = [:]
        if poses.count == 1, let pose = poses.first {
          let points = try pose.recognizedPoints(.all)
          let names: [(PostureJoint, VNHumanBodyPoseObservation.JointName)] = [(.leftEye, .leftEye), (.rightEye, .rightEye), (.nose, .nose), (.leftShoulder, .leftShoulder), (.rightShoulder, .rightShoulder)]
          for (joint, visionJoint) in names {
            if let point = points[visionJoint] {
              landmarks[joint] = PostureLandmark(x: point.location.x, y: point.location.y, confidence: Double(point.confidence))
            }
          }
        }
        // Only normalized geometry and guidance leave this autorelease scope; no frame is stored.
        let result = PostureGeometry.evaluate(points: landmarks, personCount: poses.count, width: width, height: height, time: now)
        if let sample = result.sample { emit(.observation(cameraID: device.uniqueID, sample: sample)) }
        else { emit(.trackingIssue(result.guidance ?? "Keep your face and both shoulders visible, then try calibrating again.")) }
      } catch { emit(.trackingIssue("Vision could not analyze this camera frame. Try Enable & Calibrate again.")) }
    }
  }
}

private struct PostureCaptureError: LocalizedError {
  let message: String
  init(_ message: String) { self.message = message }
  var errorDescription: String? { message }
}
