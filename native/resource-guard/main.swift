import Foundation
import Darwin

func log(_ message: String) { FileHandle.standardError.write(Data(("resource-guard: " + message + "\n").utf8)) }
func now() -> Double { ProcessInfo.processInfo.systemUptime }

final class Coordinator {
    var registry: Registry
    var policy = AdmissionPolicy()
    var sample: Sample?
    var inventoryError: String?
    var lastSample = -Double.infinity
    var lastNotification = -Double.infinity
    var pressureSince: Double?
    var notifier: Process?
    let sampler = Sampler()
    let stateURL: URL
    var savedData: Data?
    /// The full process inventory is only built when `status` asks for it, then reused briefly.
    var inventory: (time: Double, processes: [ObservedProcess])?
    #if GUARD_TESTING
    var counters: [String: Int] = [:]
    #endif

    init() {
        let url = URL(fileURLWithPath: guardHome + "/registry.json")
        let loaded = loadRegistry(url)
        stateURL = url
        registry = loaded.registry
        if let notice = loaded.notice { log(notice) }
    }

    func count(_ name: String) {
        #if GUARD_TESTING
        counters[name, default: 0] += 1
        #endif
    }

    func save() throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(registry)
        if data != savedData { try data.write(to: stateURL, options: .atomic); savedData = data }
    }

    /// Applies a request's change only if it can be saved, so a failed write reports an error and changes nothing.
    func commit(_ change: (inout Registry) -> Void) throws {
        let previous = registry
        change(&registry)
        do { try save() } catch { registry = previous; throw error }
    }

    /// Jobs need a check every second; otherwise only the 5-second resource sample is due.
    func nextDue(after time: Double) -> Double {
        let sampleDue = lastSample + 5
        return registry.jobs.isEmpty ? sampleDue : min(sampleDue, time + 1)
    }

    func statusInventory() throws -> [ObservedProcess] {
        let time = now()
        if let inventory, time - inventory.time < 2 { return inventory.processes }
        count("inventoryScans")
        let fresh = try processes()
        inventory = (time, fresh)
        return fresh
    }

    // Reconciliation reads only each job's process group; it never scans every process or its memory.
    func reconcile(_ jobs: [Job]) throws -> [Job] {
        try jobs.compactMap { original in
            var job = original
            if let group = job.group {
                count("groupScans")
                let members = try groupMembers(group)
                // Keep a reservation until the entire group exits, even if its leader exits first.
                guard !members.isEmpty else {
                    // A temporary metadata-read failure must not release a live group's slot.
                    // Signal 0 only checks existence; it never interrupts the process group.
                    if kill(-group, 0) == 0 || errno == EPERM { job.state = "unverified"; return job }
                    return nil
                }
                // Never adopt a newly reused process group on restart.
                guard members.contains(where: { job.members.contains($0.identity) }) else {
                    job.state = "unverified"
                    return job
                }
                job.members = members.map(\.identity)
                if job.state == "unverified" { job.state = job.cancelled ? "stopping" : "running" }
            } else if !alive(job.owner) { return nil }
            return job
        }
    }

    func tick() throws {
        let time = now()
        count("ticks")
        if registry.jobs.isEmpty { inventoryError = nil }
        else {
            do { registry.jobs = try reconcile(registry.jobs); inventoryError = nil }
            catch { inventoryError = "Process inventory unavailable" }
        }
        if let cached = inventory, time - cached.time >= 2 { inventory = nil }
        if time - lastSample >= 5 {
            lastSample = time
            do {
                #if GUARD_TESTING
                if let fixture = ProcessInfo.processInfo.environment["RESOURCE_GUARD_SAMPLE"] {
                    sample = try JSONDecoder().decode(Sample.self, from: Data(contentsOf: URL(fileURLWithPath: fixture)))
                    sample?.time = time
                } else { sample = try sampler.read(now: time) }
                #else
                sample = try sampler.read(now: time)
                #endif
                policy.update(sample, now: time)
            } catch { sample = nil; policy.update(nil, now: time) }
            notifyIfNeeded(time)
        }
        if inventoryError == nil, !registry.maintenance,
           policy.canStart(now: time, running: registry.jobs.filter { $0.state != "queued" }.count, limit: registry.limit),
           let index = registry.jobs.firstIndex(where: { $0.state == "queued" && !$0.cancelled }) {
            registry.jobs[index].state = "admitted"
            policy.lastStart = time
        }
        try save()
    }

    func notifyIfNeeded(_ time: Double) {
        #if GUARD_TESTING
        return
        #else
        let pressured = sample?.pressure == "warning" || sample?.pressure == "critical"
        if !pressured { pressureSince = nil; return }
        if pressureSince == nil { pressureSince = time }
        guard time - pressureSince! >= 15, time - lastNotification >= 300,
              notifier?.isRunning != true else { return }
        lastNotification = time
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", "display notification \"New heavy jobs are waiting. Open Resource Guard to inspect running work.\" with title \"Resource Guard: memory pressure\""]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try? process.run(); notifier = process
        #endif
    }

    func handle(_ input: [String: Any], peer: Int32) throws -> [String: Any] {
        guard let command = input["command"] as? String else { throw GuardError("Missing command") }
        switch command {
        case "status":
            let age = sample.map { now() - $0.time }
            // Callers that only need jobs (nested job checks) pass "processes": false to skip the scan.
            // A failed scan only empties the display list; admission keeps its own fail-closed check.
            let observed = input["processes"] as? Bool == false ? [] : (try? statusInventory()) ?? []
            let relevant = observed.filter {
                let name = $0.name.lowercased()
                return name.contains("warp") || name.contains("codex") || name.contains("claude")
            }
            var ids = Set(relevant.map { $0.identity.pid })
            while true {
                let expanded = ids.union(observed.filter { ids.contains($0.parent) }.map { $0.identity.pid })
                if expanded == ids { break }; ids = expanded
            }
            let top = observed.sorted { ($0.rss ?? 0) > ($1.rss ?? 0) }.prefix(12)
            // Bound the payload; do not include process arguments or environment variables.
            let topIDs = Set(top.map { $0.identity.pid })
            let visible = observed.filter { ids.contains($0.identity.pid) || topIDs.contains($0.identity.pid) }
                .sorted { ($0.rss ?? 0) > ($1.rss ?? 0) }.prefix(100)
            var reply: [String: Any] = ["version": 1, "limit": registry.limit,
                    "reason": registry.maintenance ? "Installation maintenance" : inventoryError ?? policy.reason,
                    "blocked": policy.blocked || inventoryError != nil || registry.maintenance,
                    "sample": try sample.map { try jsonObject($0) } ?? NSNull(),
                    "sampleAge": age as Any? ?? NSNull(),
                    "jobs": try jsonObject(registry.jobs), "processes": try jsonObject(Array(visible))]
            #if GUARD_TESTING
            reply["testing"] = counters.merging(["inventoryAge": inventory.map { Int((now() - $0.time) * 1000) } ?? -1]) { $1 }
            #endif
            return reply
        case "limit":
            guard let limit = input["value"] as? Int, [1, 2].contains(limit) else { throw GuardError("Limit must be 1 or 2") }
            try commit { $0.limit = limit }; return ["ok": true]
        case "maintenance":
            guard registry.jobs.isEmpty else { throw GuardError("Queued or running jobs must finish before installation maintenance") }
            guard !registry.maintenance else { throw GuardError("Installation maintenance is already active. If no installer is running, use resource-guard resume before retrying.") }
            try commit { $0.maintenance = true }; return ["ok": true]
        case "resume":
            try commit { $0.maintenance = false }; return ["ok": true]
        case "enqueue":
            guard !registry.maintenance else { throw GuardError("Resource Guard is being installed or removed; retry shortly") }
            guard let owner = identity(peer), let name = input["name"] as? String,
                  let directory = input["directory"] as? String, name.count <= 256, directory.count <= 4096 else {
                throw GuardError("Invalid job")
            }
            // Retrying after an uncertain socket response must not enqueue duplicate jobs.
            if let job = registry.jobs.first(where: { $0.owner == owner }) { return ["id": job.id] }
            guard registry.jobs.count < 64 else { throw GuardError("Queue is full") }
            let job = Job(id: UUID().uuidString, owner: owner, name: name, directory: directory)
            try commit { $0.jobs.append(job) }; return ["id": job.id]
        case "poll":
            count("polls")
            guard let index = jobIndex(input), registry.jobs[index].owner == identity(peer) else {
                return ["cancelled": true, "state": "finished"]
            }
            return ["state": registry.jobs[index].state, "cancelled": registry.jobs[index].cancelled,
                    "reason": inventoryError ?? (policy.blocked ? policy.reason : "Waiting for a heavy-job slot")]
        case "started":
            guard let index = jobIndex(input), let child = processInfo(peer),
                  registry.jobs[index].owner == identity(Int32(child.pbi_ppid)),
                  registry.jobs[index].state == "admitted", !registry.jobs[index].cancelled,
                  child.pbi_pgid == UInt32(peer), peer > 1,
                  let member = identity(peer) else { throw GuardError("Job start was not admitted") }
            registry.jobs[index].group = peer
            registry.jobs[index].members = [member]
            registry.jobs[index].state = "running"
            registry.jobs[index].started = Date().timeIntervalSince1970
            try save(); return ["ok": true]
        case "cancel":
            guard let index = jobIndex(input) else { throw GuardError("Job already finished") }
            let job = registry.jobs[index]
            if let group = job.group {
                guard group > 1, group != getpgrp(), job.state != "unverified",
                      job.members.contains(where: { alive($0) && processInfo($0.pid)?.pbi_pgid == UInt32(group) }) else {
                    throw GuardError("Cannot safely identify this job's process group")
                }
                guard kill(-group, input["force"] as? Bool == true ? SIGKILL : SIGTERM) == 0 || errno == ESRCH else {
                    throw GuardError("Could not cancel job")
                }
                registry.jobs[index].state = "stopping"
            }
            registry.jobs[index].cancelled = true
            try save(); return ["ok": true]
        default: throw GuardError("Unknown command")
        }
    }

    func jobIndex(_ input: [String: Any]) -> Int? {
        guard let id = input["id"] as? String else { return nil }
        return registry.jobs.firstIndex { $0.id == id }
    }
}

func serve() throws -> Never {
    umask(0o077)
    try privateDirectory(guardHome); try privateDirectory(socketDirectory)
    let lock = Darwin.open(guardHome + "/coordinator.lock", O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard lock >= 0, flock(lock, LOCK_EX | LOCK_NB) == 0 else { throw GuardError("A coordinator is already running") }
    let server = socket(AF_UNIX, SOCK_STREAM, 0)
    guard server >= 0 else { throw GuardError("Cannot create server socket") }
    socketOptions(server)
    var addr = try address()
    unlink(socketPath)
    let bound = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(server, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    guard bound == 0, listen(server, 32) == 0 else { throw GuardError("Cannot listen on Resource Guard socket") }
    chmod(socketPath, 0o600)
    let coordinator = Coordinator()
    var nextTick = -Double.infinity
    var lastFailure = ""
    while true {
        if now() >= nextTick {
            // A failed state write must never stop the service; the next tick retries it.
            do { try coordinator.tick(); lastFailure = "" } catch {
                let message = String(describing: error)
                if message != lastFailure { log("State update failed: \(message); still serving"); lastFailure = message }
            }
            nextTick = coordinator.nextDue(after: now())
        }
        coordinator.count("wakeups")
        // Sleep until the next due work or a connection: 1 s with jobs, the 5 s sample when idle.
        var item = pollfd(fd: server, events: Int16(POLLIN), revents: 0)
        let ready = poll(&item, 1, Int32(min(5_000, max(0, ((nextTick - now()) * 1000).rounded(.up)))))
        if ready < 0 && errno != EINTR { log("Socket wait failed: \(String(cString: strerror(errno)))"); usleep(100_000) }
        guard ready > 0 else { continue }
        let client = accept(server, nil, nil)
        guard client >= 0 else { continue }
        socketOptions(client)
        var command: String?
        do {
            var uid: uid_t = 0; var gid: gid_t = 0
            var pid: Int32 = 0; var size = socklen_t(MemoryLayout.size(ofValue: pid))
            guard getpeereid(client, &uid, &gid) == 0, uid == getuid(),
                  getsockopt(client, SOL_LOCAL, LOCAL_PEERPID, &pid, &size) == 0 else { throw GuardError("Unexpected client") }
            let input = try receiveJSON(client)
            command = input["command"] as? String
            try sendJSON(coordinator.handle(input, peer: pid), fd: client)
        } catch { try? sendJSON(["error": String(describing: error)], fd: client) }
        close(client)
        // Queue changes are acted on at once instead of at the next scheduled tick.
        if let command, command != "status", command != "poll" { nextTick = now() }
    }
}

func execute(_ arguments: [String]) -> Never {
    var pointers = arguments.map { strdup($0) } + [nil]
    pointers.withUnsafeMutableBufferPointer { buffer in
        _ = execvp(arguments[0], buffer.baseAddress!)
    }
    let error = errno
    log("Cannot execute \(URL(fileURLWithPath: arguments[0]).lastPathComponent): \(String(cString: strerror(error)))")
    exit(error == ENOENT ? 127 : 126)
}

// A signal handler only assigns sig_atomic_t-compatible storage; all work happens in the loop.
var receivedSignal: Int32 = 0
func rememberSignal(_ value: Int32) { receivedSignal = value }

func runJob(_ arguments: [String]) throws -> Never {
    guard !arguments.isEmpty else { throw GuardError("Usage: resource-guard run -- command [arguments]") }
    let name = URL(fileURLWithPath: arguments[0]).lastPathComponent
    guard !["codex", "claude", "warp", "Warp", "resource-guard"].contains(name) else {
        throw GuardError("Wrap a build or test command, never Warp or an agent session")
    }
    // Nested jobs are already part of an admitted process group. Validate the token with the coordinator.
    if let parentID = ProcessInfo.processInfo.environment["RESOURCE_GUARD_JOB"] {
        // Only the job list is needed; older coordinators ignore "processes" and still answer.
        let state = try request(["command": "status", "processes": false])
        if let jobs = state["jobs"] as? [[String: Any]], jobs.contains(where: {
            $0["id"] as? String == parentID && $0["group"] as? Int32 == getpgrp()
        }) { execute(arguments) }
        throw GuardError("Parent guarded job is not active")
    }
    signal(SIGINT, rememberSignal); signal(SIGTERM, rememberSignal); signal(SIGHUP, rememberSignal)
    let waiter = EventWaiter(signals: [SIGINT, SIGTERM, SIGHUP])
    // Admission and cancellation rewrite the coordinator's state file, so a change in its directory
    // (or a signal) wakes this client; the timeout only covers a missed or unwritten change.
    let watching = waiter.watchDirectory(guardHome)
    let registration = try request(["command": "enqueue", "name": name, "directory": FileManager.default.currentDirectoryPath])
    guard let id = registration["id"] as? String else { throw GuardError("Missing job ID") }
    var lastMessage = ""
    while true {
        if receivedSignal != 0 {
            _ = try? request(["command": "cancel", "id": id]); exit(128 + receivedSignal)
        }
        do {
            let response = try request(["command": "poll", "id": id])
            if response["cancelled"] as? Bool == true { log("Queued job cancelled"); exit(130) }
            if response["state"] as? String == "admitted" { break }
            let message = response["reason"] as? String ?? "Waiting"
            if message != lastMessage { log("\(message) (job \(id))"); lastMessage = message }
        } catch {
            let message = String(describing: error)
            if message != lastMessage { log(message + "; waiting safely. Ctrl-C cancels."); lastMessage = message }
        }
        waiter.wait(seconds: watching ? 5 : 0.5)
    }
    var attributes: posix_spawnattr_t?
    posix_spawnattr_init(&attributes)
    defer { posix_spawnattr_destroy(&attributes) }
    posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
    posix_spawnattr_setpgroup(&attributes, 0)
    var defaults = sigset_t(); sigemptyset(&defaults)
    for value in [SIGINT, SIGTERM, SIGHUP, SIGPIPE] { sigaddset(&defaults, value) }
    posix_spawnattr_setsigdefault(&attributes, &defaults)
    var mask = sigset_t(); sigemptyset(&mask); posix_spawnattr_setsigmask(&attributes, &mask)
    var executableBuffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
    guard proc_pidpath(getpid(), &executableBuffer, UInt32(executableBuffer.count)) > 0 else {
        throw GuardError("Cannot locate launcher executable")
    }
    let executable = String(cString: executableBuffer)
    let childArgs = [executable, "_child", id] + arguments
    var pointers = childArgs.map { strdup($0) } + [nil]
    defer { for pointer in pointers { free(pointer) } }
    var pid: Int32 = 0
    let result = pointers.withUnsafeMutableBufferPointer {
        posix_spawn(&pid, executable, nil, &attributes, $0.baseAddress!, environ)
    }
    guard result == 0 else { throw GuardError("Cannot start job: \(String(cString: strerror(result)))") }
    // Give an interactive child its own foreground terminal group; restore the caller on exit.
    let foreground = isatty(STDIN_FILENO) == 1 ? tcgetpgrp(STDIN_FILENO) : -1
    signal(SIGTTOU, SIG_IGN)
    if foreground == getpgrp() { tcsetpgrp(STDIN_FILENO, pid) }
    var status: Int32 = 0
    // Block until the child exits or a signal arrives to forward; the timeout is only a safety net.
    let watchingExit = waiter.watchExit(pid)
    while true {
        let waited = waitpid(pid, &status, WNOHANG)
        if waited == pid { break }
        if waited < 0 && errno != EINTR { throw GuardError("Could not collect job exit status") }
        if receivedSignal != 0 { kill(-pid, receivedSignal); receivedSignal = 0; continue }
        waiter.wait(seconds: watchingExit ? 5 : 0.1)
    }
    if foreground == getpgrp() { tcsetpgrp(STDIN_FILENO, foreground) }
    let code = (status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
    exit(code)
}

do {
    let args = Array(CommandLine.arguments.dropFirst())
    switch args.first {
    case "serve": try serve()
    case "run":
        guard args.count >= 3, args[1] == "--" else { throw GuardError("Usage: resource-guard run -- command [arguments]") }
        try runJob(Array(args.dropFirst(2)))
    case "_child":
        guard args.count >= 3 else { throw GuardError("Missing child command") }
        _ = try request(["command": "started", "id": args[1]])
        setenv("RESOURCE_GUARD_JOB", args[1], 1)
        execute(Array(args.dropFirst(2)))
    case "status":
        let reply = try request(["command": "status"])
        let data = try JSONSerialization.data(withJSONObject: reply, options: [.prettyPrinted, .sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    case "apps":
        print(String(decoding: try JSONEncoder().encode(memoryReport()), as: UTF8.self))
    case "quit-app":
        guard args.count == 5, let pid = Int32(args[1]), let seconds = UInt64(args[2]), let micros = UInt64(args[3]) else {
            throw GuardError("Usage: resource-guard quit-app pid start-seconds start-microseconds bundle-id")
        }
        print(try quitApplication(pid: pid, seconds: seconds, micros: micros, bundle: args[4]))
    case "cancel":
        guard args.count >= 2 else { throw GuardError("Usage: resource-guard cancel job-id [--force]") }
        _ = try request(["command": "cancel", "id": args[1], "force": args.contains("--force")])
    case "limit":
        guard args.count == 2, let value = Int(args[1]) else { throw GuardError("Usage: resource-guard limit 1|2") }
        _ = try request(["command": "limit", "value": value])
    case "maintenance", "resume":
        _ = try request(["command": args[0]])
    default: throw GuardError("Usage: resource-guard run -- command | status --json | cancel job-id [--force] | limit 1|2")
    }
} catch { log(String(describing: error)); exit(75) }
