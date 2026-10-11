import Foundation

func sample(_ time: Double, _ pressure: String = "normal", cpu: Double = 10, swap: Double = 0) -> Sample {
    Sample(time: time, pressure: pressure, cpu: cpu, swapOut: swap, swapIn: 0, swapUsed: 0, memory: 16 << 30)
}
func require(_ value: Bool, _ message: String) {
    if !value { fatalError(message) }
}

var policy = AdmissionPolicy()
require(!policy.canStart(now: 0, running: 0, limit: 2), "No admission before measurements")
for tick in stride(from: 0.0, through: 25.0, by: 5) {
    policy.update(sample(tick), now: tick)
    require(policy.blocked, "Recovery must last 30 seconds")
}
policy.update(sample(30), now: 30)
require(policy.canStart(now: 30, running: 0, limit: 2), "Healthy recovery opens queue")
require(!policy.canStart(now: 30, running: 2, limit: 2), "Global concurrency cap")
require(!policy.canStart(now: 30, running: 1, limit: 1), "Single-job setting")
policy.lastStart = 30
require(!policy.canStart(now: 39, running: 1, limit: 2), "Launch spacing")
require(policy.canStart(now: 40, running: 1, limit: 2), "Second launch after 10s")
policy.update(sample(35, "warning"), now: 35)
require(policy.blocked && policy.reason.contains("Memory pressure"), "Warning blocks immediately")
policy.update(sample(40, "critical"), now: 40)
require(policy.blocked, "Critical blocks")
policy.update(nil, now: 45)
require(policy.blocked && policy.samples.isEmpty, "Missing measurement resets recovery")
policy.update(sample(0), now: 60)
require(policy.blocked && policy.reason.contains("unavailable"), "Stale measurements block")
for tick in stride(from: 65.0, through: 95.0, by: 5) { policy.update(sample(tick), now: tick) }
require(!policy.blocked, "Recover after missing measurements")
for tick in stride(from: 100.0, through: 110.0, by: 5) { policy.update(sample(tick, cpu: 95), now: tick) }
require(policy.blocked && policy.reason.contains("CPU"), "Sustained CPU saturation blocks")
for tick in stride(from: 115.0, through: 155.0, by: 5) { policy.update(sample(tick), now: tick) }
require(!policy.blocked, "CPU hysteresis recovers")
for tick in stride(from: 160.0, through: 170.0, by: 5) { policy.update(sample(tick, swap: 11 * 1_048_576), now: tick) }
require(policy.blocked && policy.reason.contains("swap"), "Swap rate blocks, not swap allocated")
policy.update(sample(175, "unknown"), now: 175)
require(policy.blocked, "Unknown pressure fails closed")
policy.update(sample(180, cpu: .nan), now: 180)
require(policy.blocked, "Non-finite metric fails closed")
for tick in stride(from: 185.0, through: 215.0, by: 5) { policy.update(sample(tick), now: tick) }
policy.update(sample(300), now: 300)
require(policy.blocked, "Sleep/wake gap resets recovery")
print("Resource Guard policy tests passed")

func observed(_ pid: Int32, parent: Int32 = 1, executable: String, memory: UInt64? = 100) -> ObservedProcess {
    ObservedProcess(identity: Identity(pid: pid, seconds: UInt64(pid), micros: 1), parent: parent, group: pid,
                    name: URL(fileURLWithPath: executable).lastPathComponent, rss: 999, footprint: memory, executable: executable)
}
let fixtures = [
    observed(10, executable: "/Applications/Warp.app/Contents/MacOS/Warp"),
    observed(11, parent: 10, executable: "/opt/bin/codex"),
    observed(12, parent: 11, executable: "/opt/bin/node"),
    observed(20, executable: "/Applications/Browser.app/Contents/MacOS/Browser"),
    observed(21, parent: 20, executable: "/Applications/Browser.app/Contents/Helpers/Renderer", memory: 200),
    observed(22, executable: "/Applications/Browser.app/Contents/Helpers/Renderer", memory: 300),
    observed(30, executable: "/Applications/Terminal.app/Contents/MacOS/Terminal"),
    observed(31, parent: 30, executable: "/opt/bin/claude"),
    observed(32, parent: 30, executable: "/opt/bin/unrelated-command"),
    observed(40, executable: "/Applications/Notes.app/Contents/MacOS/Notes", memory: nil),
]
let apps: [AppDescriptor] = [
    AppDescriptor(identity: fixtures[0].identity, bundleID: "dev.warp.Warp-Stable", path: "/Applications/Warp.app", name: "Warp"),
    AppDescriptor(identity: fixtures[3].identity, bundleID: "test.browser", path: "/Applications/Browser.app", name: "Browser"),
    AppDescriptor(identity: fixtures[6].identity, bundleID: "test.terminal", path: "/Applications/Terminal.app", name: "Terminal"),
    AppDescriptor(identity: fixtures[9].identity, bundleID: "test.notes", path: "/Applications/Notes.app", name: "Notes"),
]
let report = appMemoryReport(apps: apps, processes: fixtures)
require(report.apps.first?.name == "Browser", "Apps sorted by estimated footprint")
let browser = report.apps.first { $0.name == "Browser" }!
require(browser.bytes == 600 && browser.processCount == 3 && !browser.protected, "Group browser helpers, including reparented helper, once")
require(report.apps.first { $0.name == "Warp" }!.protected, "Warp cannot be quit")
require(report.apps.first { $0.name == "Terminal" }!.protected, "Agent host protected even if not a known terminal bundle")
require(report.apps.first { $0.name == "Notes" }!.incomplete, "Unavailable metrics are not invented")
require(report.codingBytes == 400 && report.codingProcessCount == 4, "Coding tree footprint, not RSS")
let candidates = priorityCandidates(processes: fixtures, entries: [], enabled: true)
require(candidates == Set([10, 11, 12, 31]), "CPU priority excludes unrelated apps and terminal siblings")
let entry = PriorityEntry(identity: fixtures[1].identity, original: 0)
require(originalPriority(process: fixtures[2], processes: fixtures, entries: [entry], current: -5) == 0, "Inherited nice baseline can be restored")
require(originalPriority(process: fixtures[3], processes: fixtures, entries: [entry], current: -5) == -5, "Preserve unrelated pre-existing priority")
let stale = PriorityEntry(identity: Identity(pid: 20, seconds: 0, micros: 0), original: 0)
require(priorityCandidates(processes: fixtures, entries: [stale], enabled: false).isEmpty, "Stale PID identity is never adopted")
require(priorityCandidates(processes: fixtures, entries: [entry], enabled: false) == Set([11, 12]), "Disable includes inherited descendants")
print("RAM grouping, coding protection, and CPU priority selection tests passed")

// Exercise the actual mutation engine, including failed writes, failed syscalls, inheritance,
// and PID reuse. No real process priorities are changed by these tests.
var priorities: [Int32: Int32] = [11: -5, 12: -5]
var restores = PriorityState(enabled: false, entries: [entry])
var writes: [PriorityState] = []
try reconcilePriority(state: &restores, processes: Array(fixtures[1...2]), read: { priorities[$0.pid] }, apply: { id, value in
    if id.pid == 12 { return false }
    priorities[id.pid] = value; return true
}, persist: { writes.append($0) })
require(priorities[11] == 0 && priorities[12] == -5, "Parent restored; child syscall failed")
require(restores.entries.count == 1 && restores.entries[0].identity.pid == 12, "Failed inherited child restoration remains journaled")
require(!restores.errors.isEmpty, "Restore failure surfaced")
try reconcilePriority(state: &restores, processes: [fixtures[2]], read: { priorities[$0.pid] }, apply: { id, value in
    priorities[id.pid] = value; return true
}, persist: { writes.append($0) })
require(restores.entries.isEmpty && priorities[12] == 0, "Retry restores inherited child even after parent exits")

var enabling = PriorityState(enabled: true)
priorities = [11: 0, 12: 0]
var appliedWithoutJournal = false
try reconcilePriority(state: &enabling, processes: Array(fixtures[1...2]), read: { priorities[$0.pid] }, apply: { id, value in
    if !writes.last!.entries.contains(where: { $0.identity == id }) { appliedWithoutJournal = true }
    priorities[id.pid] = value; return true
}, persist: { writes.append($0) })
require(!appliedWithoutJournal && priorities.values.allSatisfy { $0 == -5 }, "Apply is always journaled first")
priorities[11] = -10 // A different tool changes this process after our boost.
enabling.enabled = false
try reconcilePriority(state: &enabling, processes: Array(fixtures[1...2]), read: { priorities[$0.pid] }, apply: { id, value in
    priorities[id.pid] = value; return true
}, persist: { _ in })
require(priorities[11] == -10 && priorities[12] == 0, "Respect an external priority change on disable")

var unavailableDisk = PriorityState(enabled: true)
var mutationCount = 0
do {
    try reconcilePriority(state: &unavailableDisk, processes: [fixtures[1]], read: { _ in 0 }, apply: { _, _ in mutationCount += 1; return true }, persist: { _ in throw GuardError("disk full") })
    fatalError("Expected journal error")
} catch {}
require(mutationCount == 0, "No syscall after journal failure")
var staleRestore = PriorityState(enabled: false, entries: [stale])
try reconcilePriority(state: &staleRestore, processes: [fixtures[3]], read: { _ in -5 }, apply: { _, _ in mutationCount += 1; return true }, persist: { _ in }, exists: { _ in false })
require(staleRestore.entries.isEmpty && mutationCount == 0, "Never restore a reused PID")
var metadataRetry = PriorityState(enabled: false, entries: [entry])
try reconcilePriority(state: &metadataRetry, processes: [], read: { _ in nil }, apply: { _, _ in fatalError("Missing identity must never be mutated") }, persist: { _ in }, exists: { _ in true })
require(metadataRetry.entries.count == 1 && !metadataRetry.errors.isEmpty, "Missing metadata preserves live restoration journal and surfaces error")
try reconcilePriority(state: &metadataRetry, processes: [fixtures[1]], read: { _ in nil }, apply: { _, _ in fatalError("Unreadable priority must never be mutated") }, persist: { _ in })
require(metadataRetry.entries.count == 1 && !metadataRetry.errors.isEmpty, "Unreadable priority preserves journal and surfaces error")
try reconcilePriority(state: &metadataRetry, processes: [fixtures[1]], read: { _ in -5 }, apply: { _, value in value == 0 }, persist: { _ in })
require(metadataRetry.entries.isEmpty && metadataRetry.errors.isEmpty, "Restoration succeeds when metadata becomes available again")
print("CPU mutation engine: inherited restore retry, external changes, journal failures, PID reuse passed")

let unknownCodex = AppDescriptor(identity: Identity(pid: 100, seconds: 1, micros: 1), bundleID: "com.openai.codex", path: "/Applications/Renamed.app", name: "Codex")
let unknownOther = AppDescriptor(identity: Identity(pid: 101, seconds: 1, micros: 1), bundleID: "test.unknown", path: "/Applications/Unknown.app", name: "Unknown")
let missingMetadata = appMemoryReport(apps: [unknownCodex, unknownOther], processes: [])
require(missingMetadata.apps.allSatisfy { $0.protected && $0.incomplete }, "Missing identity metadata fails closed for Quit")
let boundary = observed(102, executable: "/Applications/Browser.app.fake/Renderer")
let boundaryReport = appMemoryReport(apps: apps, processes: fixtures + [boundary])
require(boundaryReport.apps.first { $0.name == "Browser" }!.bytes == 600, "Bundle prefix uses a directory boundary")
let duplicateReport = appMemoryReport(apps: apps + [apps[0]], processes: fixtures + [fixtures[0]])
require(duplicateReport.apps.count == apps.count && duplicateReport.codingBytes == report.codingBytes, "Duplicate metadata cannot inflate memory estimates")
for invalid in [sample(400, cpu: -1), sample(400, cpu: 101), sample(400, swap: -1), sample(500)] {
    policy.update(invalid, now: 400)
    require(policy.blocked && policy.reason.contains("unavailable"), "Invalid or future measurements fail closed")
}
print("Missing identity protection, bundle boundaries, duplicate metadata, invalid metrics passed")

// Coordinator state recovery: unreadable or unsupported state is moved aside, never fatal.
let stateRoot = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("rg-state-\(getpid())-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: stateRoot, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: stateRoot) }
let stateFile = stateRoot.appendingPathComponent("registry.json")
let missingState = loadRegistry(stateFile)
require(missingState.notice == nil && missingState.registry.jobs.isEmpty && missingState.registry.limit == 2, "Missing state starts fresh silently")
try Data("{\"version\":1,\"limit\":1,\"maintenance\":false,\"jobs\":[]}".utf8).write(to: stateFile)
require(loadRegistry(stateFile).registry.limit == 1 && loadRegistry(stateFile).notice == nil, "Valid state loads unchanged")
for damaged in ["{broken", "{\"version\":99,\"limit\":1,\"maintenance\":false,\"jobs\":[]}"] {
    try Data(damaged.utf8).write(to: stateFile)
    let loaded = loadRegistry(stateFile)
    let aside = try FileManager.default.contentsOfDirectory(atPath: stateRoot.path).filter { $0.hasPrefix("registry.json.corrupt-") }
    require(loaded.notice?.contains("Moved unreadable state") == true && loaded.registry.jobs.isEmpty && loaded.registry.limit == 2,
            "Unreadable state starts fresh with a notice")
    require(!FileManager.default.fileExists(atPath: stateFile.path) && aside.count == 1
            && (try? String(contentsOf: stateRoot.appendingPathComponent(aside[0]), encoding: .utf8)) == damaged,
            "Unreadable state is moved aside byte for byte, never deleted")
    try FileManager.default.removeItem(at: stateRoot.appendingPathComponent(aside[0]))
}
print("Corrupt and unsupported coordinator state recovery passed")

// Job reconciliation reads one process group; full inventories reuse one path buffer correctly.
let ownGroup = try groupMembers(getpgrp())
require(ownGroup.contains { $0.identity.pid == getpid() } && ownGroup.allSatisfy { $0.group == getpgrp() }, "Group listing finds this process group")
require(try groupMembers(0).isEmpty, "Invalid group lists nothing")
let inventory = try processes()
func realPath(_ path: String) -> String {
    guard let resolved = realpath(path, nil) else { return path }
    defer { free(resolved) }
    return String(cString: resolved)
}
let me = inventory.first { $0.identity.pid == getpid() }
require(me.map { realPath($0.executable) } == realPath(CommandLine.arguments[0]) && me?.footprint != nil,
        "Inventory reports this process's own executable and footprint")
require(Set(inventory.map(\.executable)).count > 1, "Each process reports its own executable path")
require(try processes(includeMemory: false).allSatisfy { $0.executable.isEmpty && $0.rss == nil }, "Job-only scans never read memory or paths")
print("Process-group reconciliation and inventory path reuse passed")

// Clients wait on kernel events instead of sleep-polling.
func uptime() -> Double { ProcessInfo.processInfo.systemUptime }
let idleWaiter = EventWaiter(signals: [SIGUSR2])
var waitStart = uptime()
require(idleWaiter.wait(seconds: 0.2) == 0 && uptime() - waitStart >= 0.18, "Waiting without events sleeps for the timeout")
signal(SIGUSR2, SIG_IGN)
kill(getpid(), SIGUSR2)
waitStart = uptime()
require(idleWaiter.wait(seconds: 5) > 0 && uptime() - waitStart < 1, "A watched signal wakes the waiter at once, even when ignored")
let directoryWaiter = EventWaiter(signals: [])
require(directoryWaiter.watchDirectory(stateRoot.path), "State directory can be watched")
DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) {
    try? Data("{}".utf8).write(to: stateRoot.appendingPathComponent("registry.json"), options: .atomic)
}
waitStart = uptime()
require(directoryWaiter.wait(seconds: 5) > 0 && uptime() - waitStart < 2, "An atomic state write wakes a queued client")
let child = Process()
child.executableURL = URL(fileURLWithPath: "/bin/sleep")
child.arguments = ["0.3"]
try child.run()
let exitWaiter = EventWaiter(signals: [])
require(exitWaiter.watchExit(child.processIdentifier), "Child exit can be watched")
waitStart = uptime()
require(exitWaiter.wait(seconds: 5) > 0 && uptime() - waitStart < 2, "A child's exit wakes the waiting client without polling")
child.waitUntilExit()
print("Event-driven client waits passed")
