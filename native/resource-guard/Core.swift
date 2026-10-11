import Foundation
import Darwin

struct GuardError: Error, CustomStringConvertible {
    let description: String
    init(_ message: String) { description = message }
}

struct Sample: Codable {
    var time: Double
    var pressure: String
    var cpu: Double
    var swapOut: Double
    var swapIn: Double
    var swapUsed: UInt64
    var memory: UInt64
}

// Policy has no OS dependencies: tests advance a synthetic monotonic clock.
struct AdmissionPolicy {
    var samples: [Sample] = []
    var healthySince: Double?
    var lastStart = -Double.infinity
    var blocked = true
    var reason = "Collecting resource measurements"

    mutating func update(_ sample: Sample?, now: Double) {
        guard let sample, now >= sample.time, now - sample.time <= 10,
              sample.cpu.isFinite, (0...100).contains(sample.cpu), sample.swapOut.isFinite, sample.swapOut >= 0,
              ["normal", "warning", "critical"].contains(sample.pressure) else {
            samples = []; healthySince = nil; blocked = true
            reason = "Resource measurements unavailable"
            return
        }
        if let previous = samples.last, sample.time - previous.time > 10 {
            samples = []; healthySince = nil; blocked = true
        }
        if samples.last?.time != sample.time { samples.append(sample) }
        samples.removeAll { sample.time - $0.time >= 15 }
        let cpu = samples.map(\.cpu).reduce(0, +) / Double(samples.count)
        let swap = samples.map(\.swapOut).reduce(0, +) / Double(samples.count)
        if sample.pressure != "normal" || swap >= 10 * 1_048_576 || cpu >= 90 {
            blocked = true; healthySince = nil
            reason = sample.pressure != "normal" ? "Memory pressure: \(sample.pressure)" :
                swap >= 10 * 1_048_576 ? "High swap activity" : "High CPU usage"
        } else if blocked {
            if cpu < 80 && swap < 1_048_576 {
                if healthySince == nil { healthySince = now }
                if now - healthySince! >= 30 { blocked = false; reason = "Ready" }
                else { reason = "Waiting for 30 seconds of recovery" }
            } else { healthySince = nil; reason = "Waiting for resources to recover" }
        } else { reason = "Ready" }
    }

    func canStart(now: Double, running: Int, limit: Int) -> Bool {
        !blocked && running < limit && now - lastStart >= 10
    }
}

struct Identity: Codable, Equatable {
    var pid: Int32
    var seconds: UInt64
    var micros: UInt64
}

func processInfo(_ pid: Int32, owner: uid_t = getuid()) -> proc_bsdinfo? {
    var info = proc_bsdinfo()
    guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout.size(ofValue: info))) == MemoryLayout.size(ofValue: info),
          info.pbi_uid == owner, info.pbi_status != 5 else { return nil }
    return info
}

func identity(_ pid: Int32, owner: uid_t = getuid()) -> Identity? {
    guard let info = processInfo(pid, owner: owner) else { return nil }
    return Identity(pid: pid, seconds: info.pbi_start_tvsec, micros: info.pbi_start_tvusec)
}

func alive(_ value: Identity) -> Bool { identity(value.pid) == value }

struct ObservedProcess: Codable {
    var identity: Identity
    var parent: Int32
    var group: Int32
    var name: String
    var rss: UInt64?
    var footprint: UInt64?
    var executable: String = ""
}

/// Lists processes of one kind (all, or one process group) without reading their memory.
private func listPIDs(_ type: Int32, _ argument: UInt32) throws -> [Int32] {
    let size = proc_listpids(UInt32(type), argument, nil, 0)
    guard size >= 0 else { throw GuardError("Cannot enumerate processes") }
    var pids = [Int32](repeating: 0, count: Int(size) / 4 + 1024)
    let capacity = Int32(pids.count * 4)
    let bytes = pids.withUnsafeMutableBytes { proc_listpids(UInt32(type), argument, $0.baseAddress, capacity) }
    guard bytes >= 0, bytes < capacity else { throw GuardError("Incomplete process inventory") }
    return pids.prefix(Int(bytes) / 4).filter { $0 > 0 }
}

func observedProcess(_ pid: Int32, info: inout proc_bsdinfo) -> ObservedProcess {
    let name = withUnsafePointer(to: &info.pbi_name) {
        $0.withMemoryRebound(to: CChar.self, capacity: 32) { String(cString: $0) }
    }
    return ObservedProcess(identity: Identity(pid: pid, seconds: info.pbi_start_tvsec, micros: info.pbi_start_tvusec),
                           parent: Int32(info.pbi_ppid), group: Int32(info.pbi_pgid), name: name)
}

func processes(owner: uid_t = getuid(), includeMemory: Bool = true) throws -> [ObservedProcess] {
    let pids = try listPIDs(PROC_ALL_PIDS, 0)
    guard !pids.isEmpty else { throw GuardError("Cannot enumerate processes") }
    // One path buffer serves the whole scan.
    var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
    return pids.compactMap { pid in
        guard var info = processInfo(pid, owner: owner) else { return nil }
        var process = observedProcess(pid, info: &info)
        guard includeMemory else { return process }
        var task = proc_taskinfo()
        let read = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &task, Int32(MemoryLayout.size(ofValue: task)))
        var usage = rusage_info_v2()
        let usageResult = withUnsafeMutablePointer(to: &usage) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V2, $0) }
        }
        let pathResult = proc_pidpath(pid, &path, UInt32(path.count))
        process.rss = read == MemoryLayout.size(ofValue: task) ? task.pti_resident_size : nil
        process.footprint = usageResult == 0 ? usage.ri_phys_footprint : nil
        process.executable = pathResult > 0 ? String(cString: path) : ""
        return process
    }
}

/// The owner's live members of one process group: what job reconciliation needs, without a full scan.
func groupMembers(_ group: Int32, owner: uid_t = getuid()) throws -> [ObservedProcess] {
    guard group > 0 else { return [] }
    return try listPIDs(PROC_PGRP_ONLY, UInt32(group)).compactMap { pid in
        guard var info = processInfo(pid, owner: owner), Int32(info.pbi_pgid) == group else { return nil }
        return observedProcess(pid, info: &info)
    }
}

func sysctlValue<T>(_ name: String, _ initial: T) throws -> T {
    var value = initial
    var size = MemoryLayout<T>.size
    let result = withUnsafeMutablePointer(to: &value) { sysctlbyname(name, $0, &size, nil, 0) }
    guard result == 0, size == MemoryLayout<T>.size else {
        throw GuardError("Cannot read \(name)")
    }
    return value
}

final class Sampler {
    var previous: (time: Double, ticks: [UInt32], ins: UInt64, outs: UInt64)?
    let host = mach_host_self()
    deinit { mach_port_deallocate(mach_task_self_, host) }

    func read(now: Double) throws -> Sample? {
        var vm = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout.size(ofValue: vm) / MemoryLayout<integer_t>.size)
        let vmResult = withUnsafeMutablePointer(to: &vm) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        var cpu = host_cpu_load_info_data_t()
        count = mach_msg_type_number_t(MemoryLayout.size(ofValue: cpu) / MemoryLayout<integer_t>.size)
        let cpuResult = withUnsafeMutablePointer(to: &cpu) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard vmResult == KERN_SUCCESS, cpuResult == KERN_SUCCESS else { throw GuardError("Cannot read Mach statistics") }
        let pressure = try sysctlValue("kern.memorystatus_vm_pressure_level", Int32(0))
        let swap = try sysctlValue("vm.swapusage", xsw_usage())
        let memory = try sysctlValue("hw.memsize", UInt64(0))
        let ticks = [cpu.cpu_ticks.0, cpu.cpu_ticks.1, cpu.cpu_ticks.2, cpu.cpu_ticks.3]
        let current = (time: now, ticks: ticks, ins: vm.swapins, outs: vm.swapouts)
        defer { previous = current }
        guard let old = previous, now > old.time, vm.swapins >= old.ins, vm.swapouts >= old.outs else { return nil }
        let deltas = zip(ticks, old.ticks).map { UInt64($0 &- $1) }
        let total = deltas.reduce(0, +)
        guard total > 0 else { return nil }
        let pageSize = Double(getpagesize())
        return Sample(time: now, pressure: [1: "normal", 2: "warning", 4: "critical"][pressure] ?? "unknown",
                      cpu: 100 * (1 - Double(deltas[2]) / Double(total)),
                      swapOut: Double(vm.swapouts - old.outs) * pageSize / (now - old.time),
                      swapIn: Double(vm.swapins - old.ins) * pageSize / (now - old.time),
                      swapUsed: swap.xsu_used, memory: memory)
    }
}

struct Job: Codable {
    var id: String
    var owner: Identity
    var group: Int32?
    var members: [Identity] = []
    var name: String
    var directory: String
    var state: String = "queued"
    var created: Double = Date().timeIntervalSince1970
    var started: Double?
    var cancelled = false
}

struct Registry: Codable {
    var version = 1
    var limit = 2
    var maintenance = false
    var jobs: [Job] = []
}

/// Reads coordinator state. Unreadable or unsupported state is moved aside, never deleted, and the
/// coordinator starts fresh instead of exiting into a launchd restart loop.
func loadRegistry(_ url: URL) -> (registry: Registry, notice: String?) {
    guard FileManager.default.fileExists(atPath: url.path) else { return (Registry(), nil) }
    do {
        let registry = try JSONDecoder().decode(Registry.self, from: Data(contentsOf: url))
        guard registry.version == 1, [1, 2].contains(registry.limit) else { throw GuardError("unsupported version or limit") }
        return (registry, nil)
    } catch {
        let aside = url.path + ".corrupt-\(Int(Date().timeIntervalSince1970))-\(getpid())"
        guard rename(url.path, aside) == 0 else {
            return (Registry(), "Unreadable state (\(error)) could not be moved aside; starting fresh")
        }
        return (Registry(), "Moved unreadable state (\(error)) to \(aside); starting fresh")
    }
}

/// Sleeps until a watched signal, directory change or process exit arrives (or the timeout passes),
/// so waiting clients cost nothing between events. Without kqueue it degrades to a short sleep.
final class EventWaiter {
    private let queue = kqueue()
    private var directories: [Int32] = []

    init(signals: [Int32]) {
        for value in signals { _ = add(UInt(value), EVFILT_SIGNAL, EV_ADD, 0) }
    }
    deinit {
        for fd in directories { close(fd) }
        if queue >= 0 { close(queue) }
    }

    /// Entries added, removed or renamed in `path`, such as the coordinator's atomic state writes.
    func watchDirectory(_ path: String) -> Bool {
        let fd = open(path, O_EVTONLY | O_CLOEXEC)
        guard fd >= 0 else { return false }
        guard add(UInt(fd), EVFILT_VNODE, EV_ADD | EV_CLEAR, UInt32(NOTE_WRITE | NOTE_EXTEND | NOTE_ATTRIB)) else {
            close(fd); return false
        }
        directories.append(fd)
        return true
    }

    func watchExit(_ pid: pid_t) -> Bool { add(UInt(pid), EVFILT_PROC, EV_ADD | EV_ONESHOT, NOTE_EXIT) }

    private func add(_ ident: UInt, _ filter: Int32, _ flags: Int32, _ fflags: UInt32) -> Bool {
        guard queue >= 0 else { return false }
        var change = kevent(ident: ident, filter: Int16(filter), flags: UInt16(flags), fflags: fflags, data: 0, udata: nil)
        return kevent(queue, &change, 1, nil, 0, nil) == 0
    }

    /// Returns the number of delivered events: 0 on timeout or interruption.
    @discardableResult func wait(seconds: Double) -> Int {
        guard queue >= 0 else { usleep(useconds_t(min(seconds, 0.5) * 1_000_000)); return 0 }
        var events: [kevent] = Array(repeating: kevent(ident: 0, filter: 0, flags: 0, fflags: 0, data: 0, udata: nil), count: 8)
        var timeout = timespec(tv_sec: Int(seconds), tv_nsec: Int((seconds - seconds.rounded(.down)) * 1_000_000_000))
        return max(0, Int(kevent(queue, nil, 0, &events, Int32(events.count), &timeout)))
    }
}

func jsonObject<T: Encodable>(_ value: T) throws -> Any {
    try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
}

let guardHome = ProcessInfo.processInfo.environment["RESOURCE_GUARD_HOME"] ??
    NSHomeDirectory() + "/Library/Application Support/Productivity OS/Resource Guard"
let socketDirectory = ProcessInfo.processInfo.environment["RESOURCE_GUARD_HOME"] ??
    "/tmp/productivity-os-resource-guard-\(getuid())"
let socketPath = socketDirectory + "/guard.sock"

func privateDirectory(_ path: String) throws {
    if mkdir(path, 0o700) != 0 && errno != EEXIST {
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
    }
    var info = stat()
    guard lstat(path, &info) == 0, info.st_uid == getuid(),
          (info.st_mode & S_IFMT) == S_IFDIR, (info.st_mode & 0o077) == 0 else {
        throw GuardError("Resource Guard directory must be owned by you with mode 700: \(path)")
    }
}

func address() throws -> sockaddr_un {
    var value = sockaddr_un()
    let bytes = Array(socketPath.utf8CString)
    guard bytes.count <= MemoryLayout.size(ofValue: value.sun_path) else { throw GuardError("Socket path too long") }
    value.sun_family = sa_family_t(AF_UNIX)
    value.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    withUnsafeMutablePointer(to: &value.sun_path) {
        $0.withMemoryRebound(to: CChar.self, capacity: bytes.count) { pointer in
            for (index, byte) in bytes.enumerated() { pointer[index] = byte }
        }
    }
    return value
}

func socketOptions(_ fd: Int32) {
    var timeout = timeval(tv_sec: 2, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
    var yes: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout.size(ofValue: yes)))
    _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
}

func sendJSON(_ object: [String: Any], fd: Int32) throws {
    var bytes = try JSONSerialization.data(withJSONObject: object)
    bytes.append(10)
    try bytes.withUnsafeBytes { buffer in
        var offset = 0
        while offset < buffer.count {
            let sent = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
            if sent < 0 && errno == EINTR { continue }
            guard sent > 0 else { throw GuardError("Resource Guard connection interrupted") }
            offset += sent
        }
    }
}

func receiveJSON(_ fd: Int32) throws -> [String: Any] {
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while data.count < 1_048_576 {
        let count = Darwin.read(fd, &buffer, buffer.count)
        if count < 0 && errno == EINTR { continue }
        guard count > 0 else { throw GuardError("Resource Guard unavailable or timed out") }
        if let end = buffer.prefix(count).firstIndex(of: 10) {
            data.append(contentsOf: buffer.prefix(end))
            guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { break }
            return result
        }
        data.append(contentsOf: buffer.prefix(count))
    }
    throw GuardError("Invalid Resource Guard response")
}

func request(_ object: [String: Any]) throws -> [String: Any] {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw GuardError("Cannot create socket") }
    defer { close(fd) }
    socketOptions(fd)
    var addr = try address()
    let result = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    guard result == 0 else { throw GuardError("Resource Guard is not running. Open Resource Guard in Raycast to install or repair it.") }
    var uid: uid_t = 0; var gid: gid_t = 0
    guard getpeereid(fd, &uid, &gid) == 0, uid == getuid() else { throw GuardError("Unexpected socket owner") }
    try sendJSON(object, fd: fd)
    let response = try receiveJSON(fd)
    if let error = response["error"] as? String { throw GuardError(error) }
    return response
}
