import Foundation
import AppKit

func codingProcess(_ process: ObservedProcess) -> Bool {
    let executable = URL(fileURLWithPath: process.executable).lastPathComponent.lowercased()
    return ["warp", "warp-preview", "codex", "claude", "claude-code", "codex-code-mode-host"].contains(executable)
        || process.executable.contains("/Warp.app/") || process.executable.contains("/WarpPreview.app/")
        || process.executable.contains("/Codex.app/") || process.executable.contains("/Claude.app/")
}

func descendants(of roots: Set<Int32>, in processes: [ObservedProcess]) -> Set<Int32> {
    var result = roots
    while true {
        let expanded = result.union(processes.filter { result.contains($0.parent) }.map { $0.identity.pid })
        if expanded == result { return result }
        result = expanded
    }
}

// Ancestor hosts are protected from Quit, but their unrelated children aren't automatically boosted.
func codingProtection(_ processes: [ObservedProcess]) -> Set<Int32> {
    let roots = Set(processes.filter(codingProcess).map { $0.identity.pid })
    var protected = descendants(of: roots, in: processes)
    var ancestors = roots
    while true {
        let parents = Set(processes.filter { ancestors.contains($0.identity.pid) }.map(\.parent)).subtracting([0, 1])
        let expanded = ancestors.union(parents)
        if expanded == ancestors { break }; ancestors = expanded
    }
    protected.formUnion(ancestors)
    return protected
}

struct AppDescriptor {
    var identity: Identity
    var bundleID: String
    var path: String
    var name: String
}

struct AppMemory: Codable {
    var identity: Identity
    var bundleID: String
    var path: String
    var name: String
    var bytes: UInt64
    var processCount: Int
    var incomplete: Bool
    var protected: Bool
    var reason: String?
}

struct MemoryReport: Codable {
    var apps: [AppMemory]
    var codingBytes: UInt64
    var codingProcessCount: Int
    var codingIncomplete: Bool
    var measuredAt = Date().timeIntervalSince1970
}

func appMemoryReport(apps inputApps: [AppDescriptor], processes inputProcesses: [ObservedProcess]) -> MemoryReport {
    var appIDs = Set<Int32>(); var processIDs = Set<Int32>()
    let apps = inputApps.filter { appIDs.insert($0.identity.pid).inserted }
    let processes = inputProcesses.filter { processIDs.insert($0.identity.pid).inserted }
    let protected = codingProtection(processes)
    let codingIDs = descendants(of: Set(processes.filter(codingProcess).map { $0.identity.pid }), in: processes)
    let coding = processes.filter { codingIDs.contains($0.identity.pid) }
    var owned: [Int32: [ObservedProcess]] = [:]
    let roots = Dictionary(apps.map { ($0.identity.pid, $0) }, uniquingKeysWith: { first, _ in first })
    let parents = Dictionary(processes.map { ($0.identity.pid, $0.parent) }, uniquingKeysWith: { first, _ in first })
    for process in processes {
        var pid = process.identity.pid
        var visited = Set<Int32>()
        var owner: Int32?
        while pid > 1, visited.insert(pid).inserted {
            if roots[pid] != nil { owner = pid; break }
            pid = parents[pid] ?? 0
        }
        // Reparented app helpers can still be attributed to their bundle, without reading arguments.
        if owner == nil {
            owner = apps.filter { process.executable.hasPrefix($0.path + "/") }
                .max(by: { $0.path.count < $1.path.count })?.identity.pid
        }
        if let owner { owned[owner, default: []].append(process) }
    }
    let alwaysProtected = Set(["com.apple.finder", "com.raycast.macos", "com.apple.Terminal", "com.googlecode.iterm2",
                               "dev.warp.Warp-Stable", "dev.warp.Warp-Preview", "com.github.wez.wezterm", "net.kovidgoyal.kitty", "org.alacritty"])
    let rows = apps.map { app -> AppMemory in
        let members = owned[app.identity.pid] ?? []
        let knownCodingApp = ["warp.app", "warppreview.app", "codex.app", "claude.app"].contains(URL(fileURLWithPath: app.path).lastPathComponent.lowercased())
            || ["com.openai.codex", "com.anthropic.claudefordesktop"].contains(app.bundleID.lowercased())
        let verifiedRoot = processes.contains { $0.identity == app.identity }
        let hostsCoding = knownCodingApp || members.contains { protected.contains($0.identity.pid) }
        let isProtected = hostsCoding || alwaysProtected.contains(app.bundleID) || !verifiedRoot
        return AppMemory(identity: app.identity, bundleID: app.bundleID, path: app.path, name: app.name,
                         bytes: members.compactMap(\.footprint).reduce(0, +), processCount: members.count,
                         incomplete: members.isEmpty || members.contains { $0.footprint == nil },
                         protected: isProtected,
                         reason: hostsCoding ? "Warp, agent, or coding-session host" : !verifiedRoot ? "App identity could not be verified" : isProtected ? "System or Resource Guard interface" : nil)
    }.sorted { $0.bytes > $1.bytes }
    return MemoryReport(apps: rows, codingBytes: coding.compactMap(\.footprint).reduce(0, +),
                        codingProcessCount: coding.count, codingIncomplete: coding.contains { $0.footprint == nil })
}

func runningAppDescriptors() -> [AppDescriptor] {
    NSWorkspace.shared.runningApplications.compactMap { app in
        guard app.activationPolicy == .regular, !app.isTerminated,
              let id = identity(app.processIdentifier), let bundle = app.bundleIdentifier,
              let url = app.bundleURL else { return nil }
        return AppDescriptor(identity: id, bundleID: bundle, path: url.path, name: app.localizedName ?? bundle)
    }
}

func memoryReport() throws -> MemoryReport {
    appMemoryReport(apps: runningAppDescriptors(), processes: try processes())
}

func quitApplication(pid: Int32, seconds: UInt64, micros: UInt64, bundle: String) throws -> String {
    // Recompute protection immediately before requesting Quit; never rely on a stale UI snapshot.
    let expected = Identity(pid: pid, seconds: seconds, micros: micros)
    guard let row = try memoryReport().apps.first(where: { $0.identity == expected && $0.bundleID == bundle }) else {
        throw GuardError("This app has exited or restarted. Refresh the memory list.")
    }
    guard !row.protected else { throw GuardError("This app is protected because it supports coding or system controls") }
    guard alive(expected), let app = NSRunningApplication(processIdentifier: pid), app.bundleIdentifier == bundle else {
        throw GuardError("App identity changed; refresh the list")
    }
    guard app.terminate() else { throw GuardError("The app declined to quit. Switch to it to check for an unsaved-work prompt.") }
    return "Quit requested for \(row.name). Save any work if prompted; memory becomes available after it exits."
}
