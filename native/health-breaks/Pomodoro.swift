import Foundation
import Darwin

struct PomodoroPreferences: Codable, Equatable {
  var focusMinutes = 25
  var shortBreakMinutes = 5
  var longBreakMinutes = 15
  var roundsPerSet = 4
  var presetNames = ["social", "news"]
  var valid: Bool { (1...1440).contains(focusMinutes) && (1...240).contains(shortBreakMinutes) && (1...240).contains(longBreakMinutes) && (1...12).contains(roundsPerSet) && !presetNames.isEmpty && Set(presetNames).isSubset(of: ["social", "news", "video"]) }
  var arguments: [String] { [focusMinutes, shortBreakMinutes, longBreakMinutes, roundsPerSet].map(String.init) }
  static let defaultsKey = "pomodoroPreferences"
  static func load(_ defaults: UserDefaults) -> Self {
    guard let data = defaults.data(forKey: defaultsKey), let value = try? JSONDecoder().decode(Self.self, from: data), value.valid else { return Self() }
    return value
  }
}

struct PomodoroState: Codable, Equatable {
  enum Phase: String, Codable { case focus, shortBreak, longBreak, ready }
  var phase: Phase
  var paused: Bool
  var pauseReason: String?
  var remainingMs: Double
  var endsAt: Double?
  var focusMinutes: Int
  var shortBreakMinutes: Int
  var longBreakMinutes: Int
  var roundsPerSet: Int
  var completedRounds: Int
  var label: String
  var domains: [String]
  /// Blocker v4: no progress for 30+ min while present. Older helpers omit it.
  var stalled: Bool? = nil
  var isBreak: Bool { phase == .shortBreak || phase == .longBreak }
  var title: String {
    switch phase {
    case .focus: return "Focus"
    case .shortBreak: return "Short break"
    case .longBreak: return "Long break"
    case .ready: return "Ready for next focus"
    }
  }
  var valid: Bool {
    remainingMs.isFinite && remainingMs >= 0 && remainingMs <= 1440 * 60_000 &&
      (endsAt == nil || endsAt!.isFinite) && (1...1440).contains(focusMinutes) &&
      (1...240).contains(shortBreakMinutes) && (1...240).contains(longBreakMinutes) &&
      (1...12).contains(roundsPerSet) && completedRounds >= 0 && domains.count <= 1000
  }
}

/// An estimate for display only. The privileged helper owns every elapsed-time debit.
struct PomodoroDisplayClock {
  var state: PomodoroState?
  var sampledAt: TimeInterval = 0
  var away = false
  mutating func accept(_ value: PomodoroState?, uptime: TimeInterval) { state = value; sampledAt = uptime }
  func remaining(uptime: TimeInterval, date: Date) -> TimeInterval {
    guard let value = state, value.phase != .ready else { return 0 }
    let base = value.remainingMs / 1000
    guard !value.paused else { return base }
    if value.isBreak, let endsAt = value.endsAt { return max(0, (endsAt / 1000) - date.timeIntervalSince1970) }
    guard !away else { return base }
    // The helper credits up to 15 s between checkpoints (every 10 s ± 1 s), so the estimate runs
    // smoothly through a checkpoint; a stalled monitor still never shows more than that.
    return max(0, base - min(15, max(0, uptime - sampledAt)))
  }
  var focusRunning: Bool { state?.phase == .focus && state?.paused == false && !away }
  /// Delay until just after the displayed whole second changes, so 1 Hz ticks land on boundaries.
  static func tickDelay(remaining: TimeInterval) -> TimeInterval {
    guard remaining.isFinite, remaining > 0 else { return 1 }
    return remaining - floor(remaining) + 0.02
  }
}

/// Retries for a focus paused as away/monitor while this Mac is present, and for helper errors:
/// after 2 s, then every 10 s three times, then every 30 s.
enum PomodoroRecovery {
  static func delay(after attempt: Int) -> TimeInterval { attempt <= 0 ? 2 : attempt < 4 ? 10 : 30 }
}

enum PomodoroError: LocalizedError {
  case unavailable(String), invalidResponse, timeout, oversizedResponse, missingPresets
  var errorDescription: String? {
    switch self {
    case .unavailable(let detail): return detail.isEmpty ? "The blocking helper is unavailable. Run Setup in Raycast." : detail
    case .invalidResponse: return "The blocking helper returned an invalid Pomodoro status. Update it using Setup in Raycast."
    case .timeout: return "The blocking helper did not respond. Your existing blocks are still active."
    case .oversizedResponse: return "The blocking helper returned too much data."
    case .missingPresets: return "The Social + News presets are missing. Rebuild Health Breaks."
    }
  }
}

struct PomodoroPresets {
  struct Preset: Decodable { var name: String; var domains: [String] }
  static func domains(data: Data, selected names: [String] = ["social", "news"]) throws -> [String] {
    let presets = try JSONDecoder().decode([Preset].self, from: data)
    let selected = presets.filter { names.contains($0.name) }
    guard !selected.isEmpty, selected.count == Set(names).count, selected.allSatisfy({ !$0.domains.isEmpty }) else { throw PomodoroError.missingPresets }
    var seen = Set<String>()
    return selected.flatMap(\.domains).flatMap { [$0, "www.\($0)"] }.filter { seen.insert($0).inserted }
  }
  static func bundled(selected names: [String]) throws -> [String] {
    guard let url = Bundle.main.url(forResource: "pomodoro-presets", withExtension: "json") else { throw PomodoroError.missingPresets }
    return try domains(data: Data(contentsOf: url), selected: names)
  }
}

struct PomodoroClient {
  typealias Transport = @Sendable ([String]) async throws -> Data
  let transport: Transport
  init(transport: @escaping Transport = { try await PomodoroProcess.run(arguments: $0) }) { self.transport = transport }
  func request(_ arguments: [String]) async throws -> PomodoroState? {
    let data = try await transport(arguments)
    let state: PomodoroState?
    do { state = try JSONDecoder().decode(PomodoroState?.self, from: data) }
    catch { throw PomodoroError.invalidResponse }
    guard state?.valid != false else { throw PomodoroError.invalidResponse }
    return state
  }
}

/// Nonblocking pipe readers share a serial queue with termination and timeout handling.
/// This prevents a fast process exit from overtaking data still queued by a pipe callback.
final class PomodoroProcess: @unchecked Sendable {
  static let helper = "/Library/PrivilegedHelperTools/productivity-os/blocker.sh"
  let process = Process(), output = Pipe(), errors = Pipe()
  let queue = DispatchQueue(label: "com.productivity-os.pomodoro-process", qos: .utility)
  var stdout = Data(), stderr = Data()
  var outputSource: DispatchSourceRead?, errorSource: DispatchSourceRead?
  var continuation: CheckedContinuation<Data, Error>?
  var deadline: DispatchWorkItem?
  var finished = false
  static func run(arguments: [String], executable: String = "/usr/bin/sudo", prefix: [String] = ["-n", helper], timeout: TimeInterval = 8) async throws -> Data {
    let runner = PomodoroProcess()
    return try await withCheckedThrowingContinuation { continuation in
      runner.queue.async { runner.start(arguments: prefix + arguments, executable: executable, timeout: timeout, continuation: continuation) }
    }
  }
  private func start(arguments: [String], executable: String, timeout: TimeInterval, continuation: CheckedContinuation<Data, Error>) {
    self.continuation = continuation
    process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
    process.standardInput = FileHandle.nullDevice; process.standardOutput = output; process.standardError = errors
    func reader(_ pipe: Pipe, isError: Bool) -> DispatchSourceRead {
      let fd = pipe.fileHandleForReading.fileDescriptor
      _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
      let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
      source.setEventHandler { [weak self] in self?.drain(fd, isError: isError) }
      source.resume(); return source
    }
    outputSource = reader(output, isError: false); errorSource = reader(errors, isError: true)
    process.terminationHandler = { [self] process in
      queue.async {
        guard !self.finished else { return }
        self.drain(self.output.fileHandleForReading.fileDescriptor, isError: false)
        self.drain(self.errors.fileHandleForReading.fileDescriptor, isError: true)
        if process.terminationStatus == 0 { self.finish(.success(self.stdout)) }
        else { self.finish(.failure(PomodoroError.unavailable(Self.errorMessage(self.stderr)))) }
      }
    }
    let work = DispatchWorkItem { [self] in
      terminate(); finish(.failure(PomodoroError.timeout))
    }
    deadline = work
    do { try process.run(); queue.asyncAfter(deadline: .now() + timeout, execute: work) }
    catch { finish(.failure(PomodoroError.unavailable("Could not open the blocking helper: \(error.localizedDescription)"))) }
  }
  private func drain(_ fd: Int32, isError: Bool) {
    var buffer = [UInt8](repeating: 0, count: 4096)
    while !finished {
      let count = Darwin.read(fd, &buffer, buffer.count)
      if count < 0 && errno == EINTR { continue }
      guard count > 0 else { return }
      guard stdout.count + stderr.count + count <= 65_536 else {
        terminate(); finish(.failure(PomodoroError.oversizedResponse)); return
      }
      if isError { stderr.append(contentsOf: buffer.prefix(count)) } else { stdout.append(contentsOf: buffer.prefix(count)) }
    }
  }
  static func errorMessage(_ data: Data) -> String {
    struct Reply: Decodable { var message: String }
    if let reply = try? JSONDecoder().decode(Reply.self, from: data), !reply.message.isEmpty { return String(reply.message.prefix(500)) }
    let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return text.isEmpty ? "The blocking helper is unavailable. Run Setup in Raycast." : String(text.prefix(500))
  }
  private func terminate() {
    guard process.isRunning else { return }
    process.terminate()
    queue.asyncAfter(deadline: .now() + 0.3) { [process] in if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) } }
  }
  private func finish(_ result: Result<Data, Error>) {
    guard !finished else { return }; finished = true
    deadline?.cancel(); deadline = nil
    outputSource?.cancel(); errorSource?.cancel(); outputSource = nil; errorSource = nil
    try? output.fileHandleForReading.close(); try? errors.fileHandleForReading.close()
    process.terminationHandler = nil
    let callback = continuation; continuation = nil
    callback?.resume(with: result)
  }
}
