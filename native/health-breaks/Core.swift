import Foundation

enum BreakKind: String, Codable, CaseIterable, Hashable {
  case eyes, stretch, water
  var title: String {
    switch self { case .eyes: return "Rest your eyes"; case .stretch: return "Move and stretch"; case .water: return "Take a water break" }
  }
  var detail: String {
    switch self {
    case .eyes: return "Look at something about 6 metres (20 feet) away for 20 seconds."
    case .stretch: return "Stand up if comfortable, relax your shoulders, and move a little."
    case .water: return "Pause for a sip of water."
    }
  }
  var symbol: String {
    switch self { case .eyes: return "eye"; case .stretch: return "figure.flexibility"; case .water: return "drop" }
  }
  var defaultMinutes: Double {
    switch self { case .eyes: return 20; case .stretch: return 45; case .water: return 60 }
  }
}
struct BreakRule: Codable, Equatable {
  var enabled = true
  var minutes: Double
}
struct BreakPreferences: Codable, Equatable {
  var enabled = true
  var centered = false
  var sound = false
  var idleMinutes: Double = 2
  var rules = Dictionary(uniqueKeysWithValues: BreakKind.allCases.map { ($0.rawValue, BreakRule(minutes: $0.defaultMinutes)) })
  func validated() -> BreakPreferences {
    var value = self
    value.idleMinutes = idleMinutes.isFinite ? min(15, max(1, idleMinutes)) : 2
    for kind in BreakKind.allCases {
      var rule = rules[kind.rawValue] ?? BreakRule(minutes: kind.defaultMinutes)
      rule.minutes = rule.minutes.isFinite ? min(240, max(1, rule.minutes)) : kind.defaultMinutes
      value.rules[kind.rawValue] = rule
    }
    value.rules = value.rules.filter { BreakKind(rawValue: $0.key) != nil }
    return value
  }
}

// Pure scheduler: only input-idle duration and monotonic time are needed. No input
// contents, application names, browsing history, or activity log are collected.
struct BreakClock {
  var preferences = BreakPreferences()
  private(set) var elapsed: [BreakKind: Double] = [:]
  private(set) var snoozed: [BreakKind: Double] = [:]
  private(set) var pending = Set<BreakKind>()
  private var previous: Double?
  private var previousIdle: Double?
  private var previouslyAllowed = false
  private(set) var activeSeconds: Double = 0
  mutating func reanchor() { previous = nil; previousIdle = nil; previouslyAllowed = false }
  mutating func configure(_ value: BreakPreferences) {
    preferences = value.validated()
    for kind in BreakKind.allCases where preferences.rules[kind.rawValue]?.enabled != true {
      pending.remove(kind); elapsed[kind] = 0; snoozed[kind] = nil
    }
    if !preferences.enabled { pending = [] }
    reanchor()
  }
  mutating func sample(now: Double, idle: Double, allowed: Bool) -> Set<BreakKind> {
    guard now.isFinite, idle.isFinite, idle >= 0 else { reanchor(); return [] }
    defer { previous = now; previousIdle = idle; previouslyAllowed = allowed && preferences.enabled }
    guard let previous, let previousIdle, previouslyAllowed, preferences.enabled, allowed else { return [] }
    let delta = now - previous
    // Timer stalls, sleep, and clock discontinuities never become work time.
    guard delta > 0, delta <= 15 else { return [] }
    let threshold = preferences.idleMinutes * 60
    let active: Double
    if idle < previousIdle {
      // Input resumed. Credit only the observable recent segment, not time away.
      active = previousIdle < threshold ? delta : min(delta, idle)
    } else {
      active = min(delta, max(0, threshold - previousIdle))
    }
    guard active > 0 else { return [] }
    activeSeconds += active
    var newlyDue = Set<BreakKind>()
    for kind in BreakKind.allCases where preferences.rules[kind.rawValue]?.enabled == true && !pending.contains(kind) {
      if let remaining = snoozed[kind] {
        snoozed[kind] = max(0, remaining - active)
        if remaining <= active { snoozed[kind] = nil; pending.insert(kind); newlyDue.insert(kind) }
      } else {
        let limit = preferences.rules[kind.rawValue]!.minutes * 60
        elapsed[kind] = min(limit, (elapsed[kind] ?? 0) + active)
        if elapsed[kind]! >= limit { pending.insert(kind); newlyDue.insert(kind) }
      }
    }
    return newlyDue
  }
  mutating func complete(_ kinds: Set<BreakKind>) {
    for kind in kinds { elapsed[kind] = 0; snoozed[kind] = nil; pending.remove(kind) }
  }
  mutating func snooze(_ kinds: Set<BreakKind>, seconds: Double = 300) {
    for kind in kinds { pending.remove(kind); snoozed[kind] = max(1, seconds) }
  }
  func remaining(_ kind: BreakKind) -> Double {
    if pending.contains(kind) { return 0 }
    return snoozed[kind] ?? max(0, (preferences.rules[kind.rawValue]?.minutes ?? kind.defaultMinutes) * 60 - (elapsed[kind] ?? 0))
  }
}
