import Foundation

struct PostureBaseline: Codable, Equatable {
  var cameraID: String
  var headHeight: Double
  var shoulderWidth: Double
  var created = Date()
  var isValid: Bool { !cameraID.isEmpty && headHeight.isFinite && headHeight > 0.05 && shoulderWidth.isFinite && shoulderWidth > 0 }
}

struct PosturePreferences: Codable, Equatable {
  static let key = "posturePreferences.v1"
  var enabled = false
  var baseline: PostureBaseline?
  static func load(_ defaults: UserDefaults) -> PosturePreferences {
    guard let data = defaults.data(forKey: key), var value = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
    if value.baseline?.isValid != true { value.baseline = nil }
    return value
  }
  func save(_ defaults: UserDefaults) { if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.key) } }
}

struct PostureSample: Equatable {
  let time: TimeInterval
  let headHeight: Double
  let shoulderWidth: Double
  var isValid: Bool { time.isFinite && headHeight.isFinite && headHeight > 0.05 && shoulderWidth.isFinite && shoulderWidth > 0 }
}

enum PostureJoint: CaseIterable { case leftEye, rightEye, nose, leftShoulder, rightShoulder }
struct PostureLandmark {
  let x: Double, y: Double, confidence: Double
}
enum PostureGeometry {
  struct Result {
    let sample: PostureSample?
    let guidance: String?
  }
  static func sample(points: [PostureJoint: PostureLandmark], personCount: Int, width: Double, height: Double, time: TimeInterval) -> PostureSample? {
    evaluate(points: points, personCount: personCount, width: width, height: height, time: time).sample
  }
  static func evaluate(points: [PostureJoint: PostureLandmark], personCount: Int, width: Double, height: Double, time: TimeInterval) -> Result {
    func reject(_ guidance: String) -> Result { Result(sample: nil, guidance: guidance) }
    guard personCount > 0 else { return reject("No person detected. Move into view with your face and both shoulders visible.") }
    guard personCount == 1 else { return reject("More than one person detected. Keep only yourself in the camera view.") }
    guard width > 0, height > 0, width.isFinite, height.isFinite, time.isFinite,
      points.values.allSatisfy({ point in
        point.confidence.isFinite && (0...1).contains(point.confidence)
          && point.x.isFinite && point.y.isFinite && (0...1).contains(point.x) && (0...1).contains(point.y)
      }) else { return reject("Camera tracking returned invalid coordinates. Hold still and try again.") }
    func missing(_ joint: PostureJoint) -> Bool { points[joint] == nil || points[joint]!.confidence == 0 }
    func confident(_ joint: PostureJoint) -> Bool { (points[joint]?.confidence ?? 0) >= 0.5 }
    let face: [PostureJoint] = [.leftEye, .rightEye, .nose]
    if face.contains(where: missing) {
      return reject("Face landmarks are missing. Face the camera with both eyes and your nose visible.")
    }
    if !face.allSatisfy(confident) {
      return reject("Face tracking is uncertain. Face the camera and improve the light on your face.")
    }
    let leftClear = confident(.leftShoulder), rightClear = confident(.rightShoulder)
    if !leftClear && !rightClear {
      return reject(missing(.leftShoulder) && missing(.rightShoulder)
        ? "Both shoulders are not detected. Move back or adjust the screen until both shoulders fit in the frame."
        : "Tracking of both shoulders is uncertain. Move back and improve the light so both shoulders are clear.")
    }
    if !leftClear {
      return reject(missing(.leftShoulder)
        ? "Your left shoulder is not detected. Move back so both shoulders fit in the frame."
        : "Left shoulder tracking is uncertain. Uncover it and improve the light on your shoulders.")
    }
    if !rightClear {
      return reject(missing(.rightShoulder)
        ? "Your right shoulder is not detected. Move back so both shoulders fit in the frame."
        : "Right shoulder tracking is uncertain. Uncover it and improve the light on your shoulders.")
    }
    func location(_ joint: PostureJoint) -> (x: Double, y: Double) {
      let point = points[joint]!; return (point.x * width, point.y * height)
    }
    let left = location(.leftShoulder), right = location(.rightShoulder)
    let eyeL = location(.leftEye), eyeR = location(.rightEye), nose = location(.nose)
    let shoulderWidth = hypot(left.x - right.x, left.y - right.y)
    let eyesX = (eyeL.x + eyeR.x) / 2, eyesY = (eyeL.y + eyeR.y) / 2
    let eyeSpan = hypot(eyeL.x - eyeR.x, eyeL.y - eyeR.y)
    guard shoulderWidth > 20 else { return reject("Your shoulders appear too small. Move closer while keeping both shoulders in the frame.") }
    guard eyeSpan > 5 else { return reject("Your eyes appear too small. Move a little closer so both eyes are clearly visible.") }
    guard abs(nose.x - eyesX) / eyeSpan <= 0.6 else { return reject("Your face appears turned. Look straight toward the camera.") }
    guard abs(eyesX - (left.x + right.x) / 2) / shoulderWidth <= 0.4 else {
      return reject("Your face is off-center above your shoulders. Center yourself and look straight toward the camera.")
    }
    let result = PostureSample(time: time, headHeight: (eyesY - (left.y + right.y) / 2) / shoulderWidth,
      shoulderWidth: shoulderWidth / width)
    guard result.isValid else { return reject("Your face and shoulders overlap in the camera view. Adjust the screen so your face is clearly above your shoulders.") }
    return Result(sample: result, guidance: nil)
  }
}

/// Calibration analyses a frame every 0.5 s, so it keeps 5 fps. Monitoring analyses one frame every
/// 3–5 s, so it uses the slowest rate the active format supports, bounded at 1 fps.
enum PostureFrameRate {
  static let calibration = 5.0
  static func choose(_ ranges: [(min: Double, max: Double)], calibrating: Bool) -> Double? {
    let valid = ranges.filter { $0.min.isFinite && $0.max.isFinite && $0.min > 0 && $0.min <= $0.max }
    guard calibrating else { return valid.filter { $0.max >= 1 }.map { max(1, $0.min) }.min() ?? valid.map(\.max).max() }
    if valid.contains(where: { $0.min <= calibration && calibration <= $0.max }) { return calibration }
    return valid.min(by: { $0.min < $1.min }).map { min(max(calibration, $0.min), $0.max) }
  }
}

/// A stopped session can never publish late work into a restarted one.
struct PostureWorkGate {
  private(set) var generation: UInt64 = 0
  private(set) var active = false
  private(set) var inFlight = false
  private var lastStarted: TimeInterval = -.infinity
  @discardableResult mutating func start() -> UInt64 {
    generation &+= 1; active = true; inFlight = false; lastStarted = -.infinity; return generation
  }
  mutating func stop() { generation &+= 1; active = false; inFlight = false; lastStarted = -.infinity }
  func isCurrent(_ token: UInt64) -> Bool { active && generation == token }
  mutating func resetSchedule() { lastStarted = -.infinity }
  mutating func begin(at now: TimeInterval, interval: TimeInterval) -> UInt64? {
    guard active, !inFlight, now.isFinite, now - lastStarted >= interval else { return nil }
    inFlight = true; lastStarted = now; return generation
  }
  @discardableResult mutating func finish(_ token: UInt64) -> Bool {
    guard isCurrent(token), inFlight else { return false }; inFlight = false; return true
  }
}

/// Uses only observed head/shoulder geometry relative to a personal baseline, not a medical score.
struct PostureDriftDetector {
  static let requiredDeviationDuration: TimeInterval = 10
  private(set) var badSince: TimeInterval?
  private(set) var recoverySince: TimeInterval?
  private(set) var lastSample: TimeInterval?
  private(set) var lastNudge: TimeInterval?
  private(set) var latched = false
  var snoozedUntil: TimeInterval = 0
  mutating func interrupt() { badSince = nil; recoverySince = nil; lastSample = nil }
  mutating func snooze(at now: TimeInterval) { snoozedUntil = now + 300; latched = false; interrupt() }
  mutating func observe(_ sample: PostureSample?, baseline: PostureBaseline, at now: TimeInterval) -> Bool {
    guard now.isFinite, let sample, sample.isValid, baseline.isValid,
      abs(now - sample.time) <= 2,
      sample.shoulderWidth / baseline.shoulderWidth >= 0.75,
      sample.shoulderWidth / baseline.shoulderWidth <= 1.25 else { interrupt(); return false }
    if let lastSample, sample.time <= lastSample || sample.time - lastSample > 7 { interrupt() }
    lastSample = sample.time
    if sample.headHeight > baseline.headHeight * 0.90 {
      badSince = nil
      recoverySince = recoverySince ?? now
      if now - recoverySince! >= 10 { latched = false }
      return false
    }
    recoverySince = nil
    guard sample.headHeight <= baseline.headHeight * 0.80 else { badSince = nil; return false }
    badSince = badSince ?? now
    guard !latched, now >= snoozedUntil, now - badSince! >= Self.requiredDeviationDuration,
      lastNudge.map({ now - $0 >= 300 }) ?? true else { return false }
    latched = true; lastNudge = now
    return true
  }
}

struct PostureCalibration {
  let started: TimeInterval
  private(set) var samples: [PostureSample] = []
  mutating func observe(_ sample: PostureSample?, at now: TimeInterval) {
    guard now.isFinite else { samples.removeAll(); return }
    samples.removeAll { now - $0.time > 8 || $0.time > now }
    if let last = samples.last, now - last.time > 2 { samples.removeAll() }
    // Brief tracking loss does not erase good observations. Unknown, stale, or replayed
    // frames never count toward the ten samples or extend their freshness window.
    guard let sample, sample.isValid, sample.time <= now, now - sample.time <= 2 else { return }
    if let last = samples.last, sample.time <= last.time { return }
    samples.append(sample)
    if samples.count > 10 { samples.removeFirst() }
  }
  func baseline(cameraID: String, now: TimeInterval) -> PostureBaseline? {
    guard now - started >= 5, samples.count == 10,
      let first = samples.first, let last = samples.last, last.time - first.time >= 4,
      now.isFinite, now >= last.time, now - last.time <= 2, now - first.time <= 8 else { return nil }
    let heights = samples.map(\.headHeight).sorted(), widths = samples.map(\.shoulderWidth).sorted()
    let height = (heights[4] + heights[5]) / 2, width = (widths[4] + widths[5]) / 2
    guard heights.allSatisfy({ abs($0 / height - 1) <= 0.15 }),
      widths.allSatisfy({ abs($0 / width - 1) <= 0.15 }) else { return nil }
    let value = PostureBaseline(cameraID: cameraID, headHeight: height, shoulderWidth: width)
    return value.isValid ? value : nil
  }
}

struct PostureEligibility: Equatable {
  var monitoringAllowed = true
  var idleSeconds: TimeInterval = .infinity
  var systemAllowed = false
  var permitsCalibration: Bool { systemAllowed && idleSeconds.isFinite && idleSeconds >= 0 && idleSeconds < 120 }
  var permitsCamera: Bool { monitoringAllowed && permitsCalibration }
}

/// Targets are measured over sustained samples; they are not a claim about camera/model cost.
struct PosturePerformanceBudget {
  enum Decision: Equatable { case continueMonitoring, slowDown, pause }
  private(set) var slowed = false
  private var excessiveWindows = 0
  mutating func evaluate(cpuFraction: Double, additionalFootprint: UInt64) -> Decision {
    let excessive = cpuFraction > 0.05 || additionalFootprint > 150 * 1_048_576
    guard excessive else { excessiveWindows = 0; return .continueMonitoring }
    excessiveWindows += 1
    guard excessiveWindows >= 2 else { return .continueMonitoring }
    excessiveWindows = 0
    if !slowed { slowed = true; return .slowDown }
    return .pause
  }
}
