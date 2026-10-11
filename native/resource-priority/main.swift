import Foundation
import Darwin

// This executable is installed root-owned and only performs bounded nice changes for one user's
// coding processes. It cannot kill processes, run commands, or accept a client-supplied priority.
do {
    guard geteuid() == 0 else { throw GuardError("CPU priority requires the administrator-installed helper") }
    let arguments = Array(CommandLine.arguments.dropFirst())
    guard let command = arguments.first, ["enable", "disable", "status", "tick"].contains(command), arguments.count <= 2 else {
        throw GuardError("Usage: resource-priority enable|disable|status|tick")
    }
    let uid: uid_t
    if let caller = ProcessInfo.processInfo.environment["SUDO_UID"], let value = UInt32(caller), value > 0 {
        guard arguments.count == 1 else { throw GuardError("User commands cannot specify another account") }
        uid = value
    } else {
        guard arguments.count == 2, let value = UInt32(arguments[1]), value > 0, getpwuid(value) != nil else {
            throw GuardError("Root service requires a valid non-root user ID")
        }
        uid = value
    }
    umask(0o077)
    let directory = "/var/db/productivity-os-resource-priority"
    if mkdir(directory, 0o700) != 0 && errno != EEXIST { throw GuardError("Cannot create priority state directory") }
    var info = stat()
    guard lstat(directory, &info) == 0, info.st_uid == 0,
          info.st_mode & S_IFMT == S_IFDIR, info.st_mode & 0o077 == 0 else { throw GuardError("Unsafe priority state directory") }
    let lock = Darwin.open(directory + "/\(uid).lock", O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard lock >= 0, flock(lock, LOCK_EX) == 0 else { throw GuardError("Cannot lock priority state") }
    defer { close(lock) }
    let url = URL(fileURLWithPath: directory + "/\(uid).json")
    var state = PriorityState()
    if FileManager.default.fileExists(atPath: url.path) {
        state = try JSONDecoder().decode(PriorityState.self, from: Data(contentsOf: url))
        guard state.version == 1 else { throw GuardError("Unsupported priority state") }
    }
    func save() throws { try JSONEncoder().encode(state).write(to: url, options: .atomic) }
    if command == "enable" { state.enabled = true; try save() }
    if command == "disable" { state.enabled = false; try save() }
    if command != "status" && (state.enabled || !state.entries.isEmpty) {
        let observed = try processes(owner: uid)
        try reconcilePriority(state: &state, processes: observed, read: { expected in
            guard identity(expected.pid, owner: uid) == expected else { return nil }
            return processInfo(expected.pid, owner: uid)?.pbi_nice
        }, apply: { expected, value in
            guard identity(expected.pid, owner: uid) == expected else { return false }
            return setpriority(PRIO_PROCESS, UInt32(expected.pid), value) == 0
        }, persist: { snapshot in
            try JSONEncoder().encode(snapshot).write(to: url, options: .atomic)
        })
    }
    let result: [String: Any] = ["enabled": state.enabled, "processCount": state.entries.count,
                               "errors": state.errors, "checkedAt": state.checkedAt as Any? ?? NSNull()]
    print(String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), as: UTF8.self))
} catch {
    FileHandle.standardError.write(Data(("resource-priority: \(error)\n").utf8)); exit(1)
}
