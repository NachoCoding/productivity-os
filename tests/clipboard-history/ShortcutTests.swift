import AppKit

@MainActor func runClipboardShortcutTests() async throws {
  let app = ClipboardApp()
  let defaultsName = "clipboard-shortcut-qa-\(UUID().uuidString)"
  app.defaults = UserDefaults(suiteName: defaultsName)!
  app.board = NSPasteboard(name: .init("clipboard-shortcut-qa-\(UUID().uuidString)"))
  let userClipboard = NSPasteboard.general.changeCount
  let privateClipboard = app.board.changeCount
  var flags: NSEvent.ModifierFlags = [.command, .shift]
  var delivered: [String] = []
  let newest = Clip(id: "shortcut-newest", text: "Newest café 🙂", source: "org.test", copied: Date(), favorite: false)
  let older = Clip(id: "shortcut-older", text: "Older clip", source: "org.test", copied: Date(), favorite: false)
  let oldest = Clip(id: "shortcut-oldest", text: "Oldest clip", source: "org.test", copied: Date(), favorite: false)
  app.clips = [newest, older, oldest]; app.ready = true
  let popup = ClipboardPopup(app: app, pasteHandler: { [weak app] clip in
    delivered.append(clip.id)
    app?.popup?.window?.orderOut(nil)
  })
  app.popup = popup
  popup.modifierFlagsProvider = { flags }
  defer {
    popup.cancelShortcutInteraction()
    popup.window?.orderOut(nil); popup.window?.close()
    app.board.releaseGlobally()
    app.defaults.removePersistentDomain(forName: defaultsName)
  }
  NSApp.activate(ignoringOtherApps: true)
  func key(_ code: UInt16, flags: NSEvent.ModifierFlags = []) -> NSEvent {
    NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
      windowNumber: popup.window!.windowNumber, context: nil, characters: "",
      charactersIgnoringModifiers: "", isARepeat: false, keyCode: code)!
  }
  func waitForDelivery(_ count: Int) async throws {
    let deadline = Date().addingTimeInterval(1)
    while delivered.count < count {
      guard Date() < deadline else { throw ClipError("Shortcut release did not request its paste") }
      try await Task.sleep(nanoseconds: 5_000_000)
    }
  }

  check(app.shortcutTitle().contains("⌘⇧V") && app.defaults.object(forKey: "hotkeyCode") == nil,
    "Quick-paste behavior preserves the existing Command-Shift-V default")
  app.showHistory()
  flags = []
  popup.modifiersChanged(flags)
  check(delivered.isEmpty && popup.isShowing && !popup.holding,
    "Menu and Raycast opens remain browse-only even when modifiers are released")

  flags = [.command, .shift]
  app.showHistoryFromShortcut()
  check(popup.holding && delivered.isEmpty && popup.selected?.id == newest.id,
    "The first shortcut press arms the currently shown newest clip without Enter")
  flags = []; popup.modifiersChanged(flags)
  check(delivered == [newest.id] && !popup.isShowing && !popup.holding,
    "A quick shortcut tap pastes the shown clip as soon as modifiers release")
  popup.modifiersChanged([]); popup.pasteSelection()
  try await Task.sleep(nanoseconds: 50_000_000)
  check(delivered.count == 1, "Repeated release or Enter events cannot paste the same presentation twice")

  app.showHistoryFromShortcut()
  check(delivered.count == 2 && delivered.last == newest.id,
    "A release that happens before the popup opens still pastes exactly once")
  popup.modifiersChanged([])
  check(delivered.count == 2, "A later modifier event cannot duplicate an already completed quick tap")

  flags = [.command, .shift]
  app.showHistoryFromShortcut()
  flags = [] // Deliberately omit flagsChanged: reproduce a release lost before focus changed.
  try await waitForDelivery(3)
  check(delivered.last == newest.id && !popup.holding,
    "A release missed by the local event monitor is detected by the temporary release check")

  flags = [.command, .shift]
  app.showHistoryFromShortcut()
  app.showHistoryFromShortcut()
  check(popup.selected?.id == older.id && delivered.count == 3,
    "Repeated shortcut presses cycle history while modifiers remain held")
  _ = app.handleKey(key(125, flags: [.command, .shift]))
  check(popup.selected?.id == oldest.id, "Arrow navigation while holding updates the clip that will paste")
  flags = []; popup.modifiersChanged(flags)
  check(delivered.count == 4 && delivered.last == oldest.id,
    "Releasing after cycling pastes the displayed selection instead of the newest clip")

  app.showHistory()
  popup.move(1)
  flags = [.command, .shift]
  app.showHistoryFromShortcut()
  flags = []; popup.modifiersChanged(flags)
  check(delivered.count == 5 && delivered.last == older.id,
    "Invoking the shortcut from a browsed selection pastes that shown clip")

  flags = [.command, .shift]
  app.showHistoryFromShortcut()
  _ = app.handleKey(key(53))
  flags = []; popup.modifiersChanged(flags)
  try await Task.sleep(nanoseconds: 130_000_000)
  check(delivered.count == 5 && !popup.isShowing && !popup.holding,
    "Escape cancels shortcut release-to-paste")

  flags = [.command, .shift]
  app.showHistoryFromShortcut()
  popup.beginSearch("Older")
  flags = []; popup.modifiersChanged(flags)
  popup.endSearch()
  try await Task.sleep(nanoseconds: 40_000_000)
  check(delivered.count == 5 && popup.isShowing && !popup.holding,
    "Starting or clearing search never triggers a stale shortcut paste")

  flags = [.command, .shift]
  app.showHistoryFromShortcut()
  popup.dismiss()
  app.showHistory()
  flags = []; popup.modifiersChanged(flags)
  try await Task.sleep(nanoseconds: 150_000_000)
  check(delivered.count == 5 && popup.isShowing && !popup.holding,
    "An old dismissal cannot hide or paste an immediately reopened browse panel")

  flags = [.command, .shift]
  app.showHistoryFromShortcut()
  app.suspend(true, reason: "shortcut-fixture")
  flags = []; popup.modifiersChanged(flags)
  app.suspend(false, reason: "shortcut-fixture")
  check(delivered.count == 5 && !popup.holding,
    "Locking or suspending the helper cancels a pending shortcut paste")

  app.ready = false; app.clips = []
  app.showHistoryFromShortcut() // Modifiers are already released; storage has not loaded yet.
  check(delivered.count == 5, "A quick tap waits safely for history during cold startup")
  app.clips = [newest, older]; app.ready = true
  popup.refresh()
  check(delivered.count == 6 && delivered.last == newest.id,
    "The first quick tap pastes once when cold-start history finishes loading")
  popup.refresh()
  check(delivered.count == 6 && app.received,
    "History refresh and startup presentation cannot repeat a completed shortcut paste")

  app.ready = false; app.clips = []
  app.showHistoryFromShortcut()
  popup.dismiss()
  app.ready = true; app.clips = [newest]
  popup.refresh()
  check(delivered.count == 6, "Cancelling during history loading prevents a later surprise paste")

  app.showHistoryFromShortcut()
  check(delivered.count == 7 && delivered.last == newest.id,
    "Reopening after cancellation starts a fresh shortcut interaction")
  check(NSPasteboard.general.changeCount == userClipboard && app.board.changeCount == privateClipboard,
    "Shortcut state regressions emit no keystrokes and leave both clipboards unchanged")
}

/// Exercises the production asynchronous focus-wait loop without Accessibility or keyboard output.
@MainActor func runClipboardDelayedPasteTests() async throws {
  let app = ClipboardApp()
  let defaultsName = "clipboard-pending-paste-qa-\(UUID().uuidString)"
  app.defaults = UserDefaults(suiteName: defaultsName)!
  app.board = NSPasteboard(name: .init("clipboard-pending-paste-qa-\(UUID().uuidString)"))
  let userClipboard = NSPasteboard.general.changeCount
  let first = Clip(id: "pending-first", text: "First pending clip", source: "org.test", copied: Date(), favorite: false)
  let latest = Clip(id: "pending-latest", text: "Latest pending clip", source: "org.test", copied: Date(), favorite: false)
  app.clips = [first, latest]; app.ready = true
  app.popup = ClipboardPopup(app: app, pasteHandler: { _ in })
  app.popup?.modifierFlagsProvider = { [.command, .shift] }
  var sent: [String] = []
  var focusChecks = 0
  defer {
    app.suspend(true, reason: "fixture-complete")
    app.popup?.window?.close(); app.settings?.close()
    app.board.releaseGlobally()
    app.defaults.removePersistentDomain(forName: defaultsName)
  }
  func schedule(ready: @escaping () -> Bool = { true }) {
    app.schedulePaste(expectedChange: app.lastChange, isDestinationReady: {
      focusChecks += 1
      return ready()
    }, sendPaste: {
      sent.append(app.board.string(forType: .string) ?? "")
    })
  }
  func arm(_ clip: Clip, ready: @escaping () -> Bool = { true }) {
    app.deliver(clip, paste: false) // Same copy phase, always on the fixture's private board.
    schedule(ready: ready)
  }
  func settle() async throws { try await Task.sleep(nanoseconds: 85_000_000) }
  func waitForPost(_ count: Int) async throws {
    let deadline = Date().addingTimeInterval(1)
    while sent.count < count {
      guard Date() < deadline else { throw ClipError("Expected pending paste did not complete") }
      try await Task.sleep(nanoseconds: 5_000_000)
    }
  }

  arm(first)
  try await waitForPost(1)
  check(sent == [first.text] && focusChecks > 0,
    "Delayed paste waits asynchronously for its destination and sends exactly once")
  sent = []

  arm(first)
  let unchangedClipboard = app.board.changeCount
  app.showHistory()
  app.popup?.window?.orderOut(nil) // Hide again before the first 30 ms check: generation must still cancel it.
  try await settle()
  check(sent.isEmpty && app.board.changeCount == unchangedClipboard,
    "Rapidly reopening and hiding history cancels an already pending paste without relying on clipboard changes")

  app.showHistoryFromShortcut()
  schedule()
  app.showHistoryFromShortcut() // Repeated shortcut uses the already-visible popup branch.
  app.popup?.window?.orderOut(nil)
  try await settle()
  check(sent.isEmpty, "Repeating the shortcut cancels an earlier delayed paste even when history was already open")

  arm(first, ready: { false })
  try await Task.sleep(nanoseconds: 40_000_000)
  arm(latest)
  try await waitForPost(1)
  try await settle()
  check(sent == [latest.text], "A newer delivery supersedes an older delivery that is still waiting for focus")
  sent = []

  arm(first)
  app.deliver(latest, paste: false)
  try await settle()
  check(sent.isEmpty && app.board.string(forType: .string) == latest.text,
    "A copy-only action cancels a pending automatic paste")

  arm(first)
  let suspendChange = app.board.changeCount
  app.suspend(true, reason: "pending-fixture")
  app.suspend(false, reason: "pending-fixture")
  try await settle()
  check(sent.isEmpty && app.board.changeCount == suspendChange,
    "A brief lock or suspension cancels pending paste even if the helper resumes before its next check")

  arm(first)
  app.showSettings()
  app.settings?.close()
  try await settle()
  check(sent.isEmpty, "Opening and immediately closing Settings cancels a pending paste")

  arm(first)
  app.popup?.show() // Defense in depth for a visible popup even without an app-level open request.
  try await settle()
  app.popup?.window?.orderOut(nil)
  try await settle()
  check(sent.isEmpty, "Pending paste never sends while the clipboard popup is showing")
  check(NSPasteboard.general.changeCount == userClipboard,
    "Delayed-paste race regressions never modify the user's clipboard or send keyboard events")
}
