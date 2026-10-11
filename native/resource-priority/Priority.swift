import Foundation
import Darwin

struct PriorityEntry: Codable {
    var identity: Identity
    var original: Int32
    var applied: Int32 = -5
}

struct PriorityState: Codable {
    var version = 1
    var enabled = false
    var entries: [PriorityEntry] = []
    var errors: [String] = []
    var checkedAt: Double?
}

// Select only coding roots and their descendants, not every process hosted by a terminal.
func priorityCandidates(processes: [ObservedProcess], entries: [PriorityEntry], enabled: Bool) -> Set<Int32> {
    let existing = Set(entries.filter { entry in processes.contains { $0.identity == entry.identity } }.map { $0.identity.pid })
    let roots = enabled ? existing.union(processes.filter(codingProcess).map { $0.identity.pid }) : existing
    return descendants(of: roots, in: processes)
}

func originalPriority(process: ObservedProcess, processes: [ObservedProcess], entries: [PriorityEntry], current: Int32) -> Int32 {
    if let entry = entries.first(where: { $0.identity == process.identity }) { return entry.original }
    // New children inherit their parent's nice value. Remember the pre-boost baseline for restoration.
    guard current == -5 else { return current }
    let parents = Dictionary(processes.map { ($0.identity.pid, $0) }, uniquingKeysWith: { first, _ in first })
    var pid = process.parent
    var visited = Set<Int32>()
    while let parent = parents[pid], visited.insert(pid).inserted {
        if let entry = entries.first(where: { $0.identity == parent.identity }) { return entry.original }
        pid = parent.parent
    }
    return current
}

// All scheduling mutations go through this engine, including failure/retry and write-ahead
// journaling. Injected system calls let tests exercise the real engine without administrator access.
func reconcilePriority(state: inout PriorityState, processes: [ObservedProcess],
                       read: (Identity) -> Int32?, apply: (Identity, Int32) -> Bool,
                       persist: (PriorityState) throws -> Void,
                       exists: (Int32) -> Bool = { kill($0, 0) == 0 || errno == EPERM }) throws {
    state.entries.removeAll { entry in
        if let process = processes.first(where: { $0.identity.pid == entry.identity.pid }) {
            return process.identity != entry.identity
        }
        // Missing metadata is not proof of exit: preserve the restoration journal for retry.
        return !exists(entry.identity.pid)
    }
    state.errors = []
    for entry in state.entries where !processes.contains(where: { $0.identity == entry.identity }) {
        state.errors.append("Could not inspect process \(entry.identity.pid)")
    }
    let candidates = priorityCandidates(processes: processes, entries: state.entries, enabled: state.enabled)
    var baselines: [Int32: Int32] = [:]
    for process in processes where candidates.contains(process.identity.pid) {
        if let current = read(process.identity) {
            baselines[process.identity.pid] = originalPriority(process: process, processes: processes, entries: state.entries, current: current)
        }
    }
    for process in processes where candidates.contains(process.identity.pid) {
        guard let current = read(process.identity), let original = baselines[process.identity.pid] else {
            state.errors.append("Could not read priority for process \(process.identity.pid)")
            continue
        }
        let desired: Int32 = state.enabled ? min(current, -5) : original
        // A newly observed child also needs a restoration journal while DISABLING. Otherwise,
        // a failed child restore followed by a successful parent restore loses the retry target.
        let needsJournal = state.enabled ? original != desired : current == -5 && original != current
        if needsJournal && !state.entries.contains(where: { $0.identity == process.identity }) {
            state.entries.append(PriorityEntry(identity: process.identity, original: original))
            try persist(state)
        }
        if state.enabled {
            if desired != current && !apply(process.identity, desired) {
                state.errors.append("Could not favor process \(process.identity.pid)")
            }
        } else {
            // A different current value belongs to another tool; leave it alone.
            if current == -5 && desired != current && !apply(process.identity, desired) {
                state.errors.append("Could not restore process \(process.identity.pid)")
                continue
            }
            state.entries.removeAll { $0.identity == process.identity }
        }
    }
    state.checkedAt = Date().timeIntervalSince1970
    try persist(state)
}
