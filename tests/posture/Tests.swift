import Foundation

func require(_ condition: @autoclosure () -> Bool, _ message: String) {
  guard condition() else { print("FAIL: \(message)"); exit(1) }
  print("PASS: \(message)")
}
@main struct PostureTests {
  static func main() throws {
    let baseline = PostureBaseline(cameraID: "fixture-internal", headHeight: 0.5, shoulderWidth: 0.5)
    func sample(_ time: Double, height: Double = 0.35, width: Double = 0.5) -> PostureSample {
      PostureSample(time: time, headHeight: height, shoulderWidth: width)
    }
    require(!PostureEligibility().permitsCamera, "Automatic monitoring waits until activity and system state are known")
    require(!PostureEligibility().permitsCalibration, "Calibration stays unavailable until activity and system state are known")
    let setup = PostureEligibility(monitoringAllowed: true, idleSeconds: 0, systemAllowed: true)
    require(setup.permitsCalibration && setup.permitsCamera,
      "An active unlocked user can calibrate and receive reminders independently of Pomodoro")
    let paused = PostureEligibility(monitoringAllowed: false, idleSeconds: 0, systemAllowed: true)
    require(paused.permitsCalibration && !paused.permitsCamera,
      "Health reminder pause stops automatic monitoring while still allowing explicit calibration")
    for state in [PostureEligibility(monitoringAllowed: false, idleSeconds: 0, systemAllowed: true),
      PostureEligibility(monitoringAllowed: true, idleSeconds: 120, systemAllowed: true),
      PostureEligibility(monitoringAllowed: true, idleSeconds: 1, systemAllowed: false),
      PostureEligibility(monitoringAllowed: true, idleSeconds: .nan, systemAllowed: true)] {
      require(!state.permitsCamera, "Health pause, idle, sleep/lock, and invalid activity never permit automatic monitoring")
    }
    for state in [PostureEligibility(monitoringAllowed: false, idleSeconds: 120, systemAllowed: true),
      PostureEligibility(monitoringAllowed: true, idleSeconds: 0, systemAllowed: false),
      PostureEligibility(monitoringAllowed: false, idleSeconds: .nan, systemAllowed: true),
      PostureEligibility(monitoringAllowed: false, idleSeconds: -1, systemAllowed: true)] {
      require(!state.permitsCalibration && !state.permitsCamera,
        "Idle, locked/sleeping, or invalid activity rejects both explicit calibration and monitoring")
    }
    let points: [PostureJoint: PostureLandmark] = [
      .leftEye: .init(x: 0.45, y: 0.75, confidence: 0.9),
      .rightEye: .init(x: 0.55, y: 0.75, confidence: 0.9),
      .nose: .init(x: 0.5, y: 0.70, confidence: 0.9),
      .leftShoulder: .init(x: 0.3, y: 0.4, confidence: 0.9),
      .rightShoulder: .init(x: 0.7, y: 0.4, confidence: 0.9)]
    func geometry(_ values: [PostureJoint: PostureLandmark], people: Int = 1) -> PostureSample? {
      PostureGeometry.sample(points: values, personCount: people, width: 640, height: 480, time: 1)
    }
    func guidance(_ values: [PostureJoint: PostureLandmark], people: Int = 1) -> String {
      PostureGeometry.evaluate(points: values, personCount: people, width: 640, height: 480, time: 1).guidance?.lowercased() ?? ""
    }
    require(abs(geometry(points)!.headHeight - 0.65625) < 0.00001,
      "Head/shoulder ratio accounts for the camera pixel aspect ratio")
    for joint in PostureJoint.allCases {
      var partial = points; partial[joint] = nil
      require(geometry(partial) == nil, "A missing face or shoulder landmark makes a partial observation unknown")
      let region = joint == .leftShoulder ? "left shoulder" : joint == .rightShoulder ? "right shoulder" : "face"
      require(guidance(partial).contains(region), "Missing-landmark guidance identifies the affected face or shoulder")
      partial = points; let point = partial[joint]!
      partial[joint] = .init(x: point.x, y: point.y, confidence: 0.49)
      require(geometry(partial) == nil, "Any low-confidence face or shoulder landmark suppresses scoring")
      require(guidance(partial).contains(region) && guidance(partial).contains("uncertain"),
        "Low-confidence guidance identifies which face or shoulder tracking needs improvement")
    }
    require(geometry(points, people: 0) == nil && geometry(points, people: 2) == nil,
      "Absent or multiple people do not produce a posture sample")
    require(guidance([:], people: 0).contains("no person") && guidance([:], people: 2).contains("more than one person"),
      "Guidance distinguishes no detected person from multiple people")
    require(guidance(points).isEmpty, "A valid geometry sample carries no failure guidance")
    var profile = points; profile[.nose] = .init(x: 0.62, y: 0.7, confidence: 0.9)
    require(geometry(profile) == nil, "Turned-away facial geometry does not produce a misleading sample")
    require(guidance(profile).contains("turned"), "Turned-face guidance explains the geometry rejection")
    var invalid = points; invalid[.leftEye] = .init(x: .nan, y: 0.7, confidence: 0.9)
    require(geometry(invalid) == nil, "Invalid landmark coordinates never enter calibration or scoring")
    require(guidance(invalid).contains("invalid coordinates"), "Invalid numeric geometry has a distinct diagnostic")
    var shoulders = points; shoulders[.leftShoulder] = nil; shoulders[.rightShoulder] = nil
    require(guidance(shoulders).contains("both shoulders") && guidance(shoulders).contains("move back"),
      "Two missing shoulders get actionable wider-framing guidance")
    var offCenter = points
    offCenter[.leftEye] = .init(x: 0.7, y: 0.75, confidence: 0.9)
    offCenter[.rightEye] = .init(x: 0.8, y: 0.75, confidence: 0.9)
    offCenter[.nose] = .init(x: 0.75, y: 0.7, confidence: 0.9)
    require(geometry(offCenter) == nil && guidance(offCenter).contains("off-center"),
      "Off-center head position is distinguished from uncertain landmarks")
    var tooSmall = points
    tooSmall[.leftShoulder] = .init(x: 0.49, y: 0.4, confidence: 0.9)
    tooSmall[.rightShoulder] = .init(x: 0.51, y: 0.4, confidence: 0.9)
    require(geometry(tooSmall) == nil && guidance(tooSmall).contains("move closer"),
      "A shoulder span too small for scoring gives distance guidance")
    let builtIn: [(min: Double, max: Double)] = [(1, 30)]
    require(PostureFrameRate.choose(builtIn, calibrating: true) == 5 && PostureFrameRate.choose(builtIn, calibrating: false) == 1,
      "Calibration keeps 5 fps while monitoring uses the camera's slowest supported rate")
    require(PostureFrameRate.choose([(0.25, 30)], calibrating: false) == 1, "Monitoring never asks the camera for less than one frame per second")
    require(PostureFrameRate.choose([(15, 30)], calibrating: false) == 15 && PostureFrameRate.choose([(15, 30)], calibrating: true) == 15,
      "A camera without slow modes uses its lowest available rate in both modes")
    require(PostureFrameRate.choose([(7.5, 30), (2, 2)], calibrating: false) == 2 && PostureFrameRate.choose([(7.5, 30), (3, 6)], calibrating: true) == 5,
      "Monitoring picks the slowest of several ranges; calibration uses any range containing 5 fps")
    require(PostureFrameRate.choose([(0.2, 0.5)], calibrating: false) == 0.5, "A camera that cannot reach 1 fps monitors at its fastest available rate")
    require(PostureFrameRate.choose([], calibrating: false) == nil && PostureFrameRate.choose([(.nan, 30), (5, 1), (0, 0)], calibrating: true) == nil,
      "Missing or invalid frame-rate ranges are rejected instead of configuring the camera")
    var gate = PostureWorkGate()
    require(gate.begin(at: 0, interval: 3) == nil, "An inactive capture never schedules inference")
    let firstGeneration = gate.start()
    require(gate.begin(at: 0, interval: 3) == firstGeneration, "An eligible capture schedules its first inference")
    require(gate.begin(at: 10, interval: 3) == nil, "Only one inference may be in flight even when newer frames arrive")
    require(gate.finish(firstGeneration), "The current inference may publish once")
    require(gate.begin(at: 2.99, interval: 3) == nil && gate.begin(at: 3, interval: 3) != nil,
      "Dropped frames do not become a backlog or bypass the analysis interval")
    gate.stop()
    require(!gate.isCurrent(firstGeneration) && !gate.finish(firstGeneration),
      "Stopping capture invalidates an in-flight result immediately")
    let nextGeneration = gate.start(); _ = gate.begin(at: 4, interval: 3)
    require(!gate.finish(firstGeneration) && gate.inFlight && gate.isCurrent(nextGeneration),
      "A late result cannot finish or publish into a restarted capture")
    require(gate.finish(nextGeneration), "A restarted capture accepts only its own result")
    var detector = PostureDriftDetector()
    for time in [0.0, 3, 6, 9, 9.99] {
      require(!detector.observe(sample(time), baseline: baseline, at: time), "Brief deviation does not nudge")
    }
    require(detector.observe(sample(10), baseline: baseline, at: 10), "Sustained confident deviation nudges at ten seconds")
    require(!detector.observe(sample(13), baseline: baseline, at: 13), "One posture event never creates repeated immediate nudges")
    var boundary = PostureDriftDetector()
    for time in [0.0, 3, 6, 9, 9.99] {
      require(!boundary.observe(sample(time, height: 0.4), baseline: baseline, at: time),
        "An exact twenty-percent deviation still waits until ten seconds")
    }
    require(boundary.observe(sample(10, height: 0.4), baseline: baseline, at: 10),
      "An exact twenty-percent height reduction reaches the threshold despite floating-point rounding")
    for time in stride(from: 16.0, through: 28, by: 3) { _ = detector.observe(sample(time, height: 0.48), baseline: baseline, at: time) }
    require(!detector.latched, "Ten seconds of recovery clears the active deviation")
    for time in stride(from: 31.0, through: 70, by: 3) {
      require(!detector.observe(sample(time), baseline: baseline, at: time), "Five-minute cooldown suppresses repeat prompts")
    }
    detector = PostureDriftDetector()
    for time in stride(from: 0.0, through: 9, by: 3) { _ = detector.observe(sample(time), baseline: baseline, at: time) }
    require(!detector.observe(nil, baseline: baseline, at: 9.5), "Unknown landmarks do not count as a posture deviation")
    for time in [10.0, 13, 16, 19, 19.99] { require(!detector.observe(sample(time), baseline: baseline, at: time), "Unknown observation resets sustained-deviation time") }
    require(detector.observe(sample(20), baseline: baseline, at: 20), "A new complete ten-second interval is required after unknown tracking")
    detector = PostureDriftDetector()
    _ = detector.observe(sample(0), baseline: baseline, at: 0)
    require(!detector.observe(sample(60), baseline: baseline, at: 60), "Sleep or processing stalls cannot become observed bad-posture time")
    require(!detector.observe(sample(60), baseline: baseline, at: 70), "Late inference results cannot trigger a nudge")
    require(!detector.observe(sample(73, width: 0.8), baseline: baseline, at: 73) && detector.badSince == nil,
      "Large framing changes suppress posture scoring")
    detector.snooze(at: 100)
    for time in stride(from: 360.0, through: 399, by: 3) {
      require(!detector.observe(sample(time), baseline: baseline, at: time), "Snooze prevents prompts until its deadline")
    }
    require(detector.observe(sample(402), baseline: baseline, at: 402), "Snoozed coaching may nudge again after five minutes")

    var calibration = PostureCalibration(started: 0)
    for i in 0..<9 { let time = Double(i) * 0.5 + 0.5; calibration.observe(sample(time, height: 0.5), at: time) }
    require(calibration.baseline(cameraID: baseline.cameraID, now: 5) == nil, "Calibration needs ten confident samples")
    calibration.observe(sample(5, height: 0.5), at: 5)
    require(calibration.baseline(cameraID: baseline.cameraID, now: 5)?.headHeight == 0.5,
      "Stable five-second calibration records only normalized geometry")
    require(calibration.baseline(cameraID: baseline.cameraID, now: 20) == nil,
      "A stalled main thread cannot turn an old sample window into a new calibration")
    calibration.observe(sample(5.5, height: 0.5), at: 20)
    require(calibration.samples.isEmpty, "Queued camera observations older than two seconds clear calibration evidence")
    calibration.observe(sample(20, height: 0.5), at: 20)
    require(calibration.samples.count == 1 && calibration.baseline(cameraID: baseline.cameraID, now: 20) == nil,
      "Calibration after a stall requires a fresh complete sample window")
    calibration.observe(nil, at: 20.5)
    require(calibration.samples.count == 1, "A brief unknown frame preserves recent confident calibration samples")
    calibration.observe(nil, at: 22.01)
    require(calibration.samples.isEmpty, "More than two seconds without a good sample clears calibration progress")
    calibration = PostureCalibration(started: 0)
    for i in 1...9 { let time = Double(i) * 0.5; calibration.observe(sample(time, height: 0.5), at: time) }
    calibration.observe(nil, at: 5)
    require(calibration.samples.count == 9 && calibration.baseline(cameraID: baseline.cameraID, now: 5) == nil,
      "A missing tenth frame keeps nine good samples without counting the unknown frame")
    calibration.observe(sample(5.5, height: 0.5), at: 5.5)
    require(calibration.baseline(cameraID: baseline.cameraID, now: 5.5)?.headHeight == 0.5,
      "Calibration succeeds after a short dropout when ten real steady observations are available")
    calibration = PostureCalibration(started: 0)
    calibration.observe(sample(4.5, height: 0.5), at: 4.5)
    calibration.observe(sample(2, height: 0.5), at: 5)
    calibration.observe(sample(4.5, height: 0.5), at: 5)
    require(calibration.samples.count == 1 && calibration.samples.last?.time == 4.5,
      "Stale and replayed frames neither count as new samples nor refresh their freshness")
    calibration.observe(sample(7, height: 0.5), at: 7)
    require(calibration.samples.count == 1 && calibration.samples.first?.time == 7,
      "A valid sample after a long tracking gap starts a fresh collection")
    calibration = PostureCalibration(started: 0)
    for i in 0...10 { let time = Double(i); calibration.observe(sample(time, height: 0.5), at: time) }
    require(calibration.samples.count == 9 && calibration.samples.first?.time == 2
      && calibration.baseline(cameraID: baseline.cameraID, now: 10) == nil,
      "Sparse tracking cannot accumulate ten samples from beyond the eight-second window")
    calibration = PostureCalibration(started: 0)
    for i in 0..<40 { let time = Double(i) * 0.5; calibration.observe(sample(time, height: 0.5), at: time) }
    require(calibration.samples.count == 10 && calibration.samples.first?.time == 15,
      "Long calibration attempts retain at most the ten most recent confident samples")
    require(calibration.baseline(cameraID: baseline.cameraID, now: 22) == nil,
      "A complete sample window cannot save a baseline once the last good observation is stale")
    calibration = PostureCalibration(started: 0)
    var uncertain = points
    uncertain[.leftShoulder] = .init(x: 0.3, y: 0.4, confidence: 0.49)
    for i in 0..<20 {
      let time = Double(i) * 0.5
      let rejected = PostureGeometry.sample(points: uncertain, personCount: 1, width: 640, height: 480, time: time)
      calibration.observe(rejected, at: time)
    }
    require(calibration.samples.isEmpty && calibration.baseline(cameraID: baseline.cameraID, now: 10) == nil,
      "Low-confidence-only tracking can never produce calibration")
    calibration = PostureCalibration(started: 0)
    for i in 0..<10 { let time = Double(i) * 0.5 + 0.5; calibration.observe(sample(time, height: i == 4 ? 0.9 : 0.5), at: time) }
    require(calibration.baseline(cameraID: baseline.cameraID, now: 5) == nil, "Unsteady calibration is rejected instead of learning a misleading baseline")
    calibration = PostureCalibration(started: 0)
    for i in 0..<10 {
      let time = Double(i) * 0.5 + 0.5
      calibration.observe(sample(time, height: 0.5, width: i == 4 ? 0.8 : 0.5), at: time)
    }
    require(calibration.baseline(cameraID: baseline.cameraID, now: 5) == nil,
      "Dropout tolerance does not weaken shoulder-width stability requirements")

    var budget = PosturePerformanceBudget()
    require(budget.evaluate(cpuFraction: 0.02, additionalFootprint: 30 * 1_048_576) == .continueMonitoring,
      "Within-budget coaching keeps the normal analysis rate")
    require(budget.evaluate(cpuFraction: 0.08, additionalFootprint: 30 * 1_048_576) == .continueMonitoring,
      "One short resource spike does not stop coaching")
    require(budget.evaluate(cpuFraction: 0.08, additionalFootprint: 30 * 1_048_576) == .slowDown,
      "Sustained CPU over budget reduces analysis to every five seconds")
    _ = budget.evaluate(cpuFraction: 0.02, additionalFootprint: 151 * 1_048_576)
    require(budget.evaluate(cpuFraction: 0.02, additionalFootprint: 151 * 1_048_576) == .pause,
      "Persistent footprint over budget pauses coaching after reducing its rate")
    let suite = "posture-tests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(Data("existing reminder preferences".utf8), forKey: "preferences")
    var prefs = PosturePreferences.load(defaults)
    require(!prefs.enabled && prefs.baseline == nil, "Missing posture preferences remain opt-in")
    prefs.enabled = true; prefs.baseline = baseline; prefs.save(defaults)
    require(PosturePreferences.load(defaults) == prefs, "Posture preferences and numeric calibration survive restart")
    require(defaults.data(forKey: "preferences") == Data("existing reminder preferences".utf8), "Posture settings never replace existing reminder settings")
    defaults.set(Data("corrupt".utf8), forKey: PosturePreferences.key)
    require(!PosturePreferences.load(defaults).enabled, "Corrupt posture settings fail closed with coaching off")
    print("Posture pure tests complete; no camera was accessed")
  }
}
