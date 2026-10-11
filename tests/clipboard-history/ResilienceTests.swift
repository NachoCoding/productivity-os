import AppKit
import CryptoKit
import SQLite3

/// Storage recovery, retries, menu, polling, expiry and login registration. Nothing here shows a
/// window, activates the app, or touches real history, the Keychain or the user's clipboard.
@MainActor func runClipboardResilienceTests(root: URL) async throws {
  let key = SymmetricKey(size: .bits256)
  func rows(_ url: URL) throws -> Int {
    var db: OpaquePointer?
    guard sqlite3_open(url.path, &db) == SQLITE_OK else { throw ClipError("fixture open") }
    defer { sqlite3_close(db) }
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(db, "SELECT count(*) FROM clips", -1, &statement, nil) == SQLITE_OK,
      sqlite3_step(statement) == SQLITE_ROW
    else { throw ClipError("fixture count") }
    defer { sqlite3_finalize(statement) }
    return Int(sqlite3_column_int(statement, 0))
  }
  func foreignPayload() throws -> String {
    try AES.GCM.seal(Data("{}".utf8), using: SymmetricKey(size: .bits256)).combined!
      .map { String(format: "%02x", $0) }.joined()
  }

  let damagedURL = root.appendingPathComponent("damaged.sqlite")
  let seeded = try ClipStore(url: damagedURL, key: key)
  for text in ["alpha", "beta", "gamma", "delta"] { try seeded.add(text, source: "org.test") }
  try sql(damagedURL, "UPDATE clips SET payload=x'000102' WHERE rowid=(SELECT min(rowid) FROM clips)")
  let recovered = try ClipStore(url: damagedURL, key: key)
  check(recovered.clips.count == 3 && recovered.skipped == 1,
    "One damaged entry is skipped and counted; the rest of history opens")
  check(try rows(damagedURL) == 3 && ClipStore(url: damagedURL, key: key).skipped == 0,
    "Skipped entries are removed so the next open is clean")
  try sql(damagedURL, "UPDATE clips SET payload=x'\(try foreignPayload())' WHERE rowid=(SELECT min(rowid) FROM clips)")
  try sql(damagedURL, "UPDATE clips SET id='bogus' WHERE rowid=(SELECT max(rowid) FROM clips)")
  let mixed = try ClipStore(url: damagedURL, key: key)
  check(mixed.clips.count == 1 && mixed.skipped == 2,
    "Entries failing authentication or identity checks are skipped once other entries prove the key")

  let foreignURL = root.appendingPathComponent("foreign.sqlite")
  let foreign = try ClipStore(url: foreignURL, key: key)
  try foreign.add("one", source: "")
  try foreign.add("two", source: "")
  fails("History under another key still fails closed") {
    _ = try ClipStore(url: foreignURL, key: SymmetricKey(size: .bits256))
  }
  try sql(foreignURL, "UPDATE clips SET payload=x'\(try foreignPayload())'")
  fails("History where no entry authenticates fails closed") { _ = try ClipStore(url: foreignURL, key: key) }
  check(try rows(foreignURL) == 2, "A key mismatch never removes entries")

  let limitsURL = root.appendingPathComponent("trim-limits.sqlite")
  let large = try ClipStore(url: limitsURL, key: key)
  for n in 0..<5 { try large.add("entry-\(n)", source: "", now: Date().addingTimeInterval(Double(n))) }
  let trimmed = try ClipStore(
    url: limitsURL, key: key,
    limits: ClipLimits(ordinary: 2, favorites: 1, itemBytes: 100, totalBytes: 1000, age: 86_400))
  check(try trimmed.clips.map(\.text) == ["entry-4", "entry-3"] && rows(limitsURL) == 2,
    "History beyond the current limits keeps its newest entries instead of failing to open")

  let asideURL = root.appendingPathComponent("aside.sqlite")
  try Data("not a database".utf8).write(to: asideURL)
  let moved = try ClipStore.moveAside(asideURL)
  check(moved.flatMap { try? Data(contentsOf: $0) } == Data("not a database".utf8)
      && !FileManager.default.fileExists(atPath: asideURL.path),
    "Reset moves unreadable history aside byte for byte")

  // One fixed throwaway defaults domain, emptied before and after, so no preference files pile up.
  let suite = "com.productivity-os.clipboard-resilience-qa"
  UserDefaults.standard.removePersistentDomain(forName: suite)
  var apps: [ClipboardApp] = []
  func makeApp(_ path: String) -> ClipboardApp {
    let app = ClipboardApp()
    apps.append(app)
    app.defaults = UserDefaults(suiteName: suite)!
    app.board = NSPasteboard(name: .init("clipboard-resilience-qa-" + UUID().uuidString))
    app.storeURL = root.appendingPathComponent(path)
    app.storeKey = key
    app.launched = true
    return app
  }
  defer {
    for app in apps {
      app.shutdownRequested = true
      app.stopTimers()
      app.popup?.window?.close()
      app.board.releaseGlobally()
    }
    UserDefaults.standard.removePersistentDomain(forName: suite)
  }
  func put(_ app: ClipboardApp, _ text: String) {
    let item = NSPasteboardItem()
    item.setString(text, forType: .string)
    app.board.clearContents()
    app.board.writeObjects([item])
  }
  func waitFor(_ message: String, _ condition: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(3)
    while !condition() {
      guard Date() < deadline else { throw ClipError(message) }
      try await Task.sleep(nanoseconds: 20_000_000)
    }
  }
  func menuTitles(_ app: ClipboardApp) -> [String] {
    let menu = NSMenu()
    app.menuNeedsUpdate(menu)
    return menu.items.map(\.title)
  }

  // A file where the history folder belongs keeps storage from opening.
  let blocked = makeApp("blocked/history.sqlite")
  try Data().write(to: root.appendingPathComponent("blocked"))
  await blocked.openStore()
  check(!blocked.ready && blocked.storeProblem != nil && blocked.storeAttempts == 1,
    "Unavailable storage leaves history closed with a reason")
  let unavailableMenu = menuTitles(blocked)
  check(unavailableMenu.first?.hasPrefix("History unavailable — ") == true
      && unavailableMenu.contains("Retry Opening History") && unavailableMenu.contains("Open Clipboard History"),
    "The menu says history is unavailable and offers Retry")
  try FileManager.default.removeItem(at: root.appendingPathComponent("blocked"))
  blocked.lastChange = blocked.board.changeCount
  put(blocked, "copied during backoff")
  blocked.poll()
  try await Task.sleep(nanoseconds: 100_000_000)
  check(blocked.storeAttempts == 1 && !blocked.ready, "Copies inside the backoff window do not retry storage")
  blocked.nextStoreRetry = 0
  put(blocked, "copy that retries storage")
  blocked.poll()
  try await waitFor("A copy did not retry storage") { blocked.ready && !blocked.clips.isEmpty }
  check(blocked.storeAttempts == 2 && blocked.storeProblem == nil
      && blocked.clips.map(\.text) == ["copy that retries storage"],
    "The next copy retries storage and keeps that copy once history opens")

  let locked = makeApp("locked/history.sqlite")
  try Data().write(to: root.appendingPathComponent("locked"))
  await locked.openStore()
  try FileManager.default.removeItem(at: root.appendingPathComponent("locked"))
  locked.suspend(true, reason: "lock")
  check(locked.timer == nil && !locked.ready, "Nothing checks the clipboard while the screen is locked")
  locked.suspend(false, reason: "lock")
  try await waitFor("Unlock did not retry storage") { locked.ready }
  check(locked.storeAttempts == 2 && locked.timer != nil,
    "Unlocking retries storage at once, ignoring backoff, and resumes clipboard checks")

  let reset = makeApp("reset.sqlite")
  try Data("not a database, just text".utf8).write(to: reset.storeURL)
  await reset.openStore()
  check(!reset.ready && reset.storeResettable && menuTitles(reset).contains("Reset History…"),
    "An unreadable history file offers Reset History")
  await reset.resetStore()
  let asides = try FileManager.default.contentsOfDirectory(atPath: root.path).filter {
    $0.hasPrefix("reset-unreadable-")
  }
  check(reset.ready && reset.clips.isEmpty && asides.count == 1
      && (try? Data(contentsOf: root.appendingPathComponent(asides[0]))) == Data("not a database, just text".utf8),
    "Reset moves the unreadable file aside and starts an empty history")
  check(menuTitles(reset).first == reset.problem && !menuTitles(reset).contains("Reset History…"),
    "A working history no longer offers Retry or Reset")
  reset.shortcutProblem = "Global shortcut is already in use. Choose another shortcut in Clipboard History Settings."
  check(menuTitles(reset).contains(reset.shortcutProblem!) && menuTitles(reset).contains("Change Shortcut…"),
    "The menu shows a shortcut registration problem and how to fix it")
  reset.shortcutProblem = nil

  let app = reset
  app.updatePolling()
  guard let pollTimer = app.timer else { throw ClipError("Clipboard check timer missing") }
  let cfTimer = unsafeBitCast(pollTimer, to: CFRunLoopTimer.self)
  check(pollTimer.tolerance >= 0.2
      && CFRunLoopContainsTimer(CFRunLoopGetMain(), cfTimer, CFRunLoopMode(RunLoop.Mode.eventTracking.rawValue as CFString))
      && CFRunLoopContainsTimer(CFRunLoopGetMain(), cfTimer, CFRunLoopMode(RunLoop.Mode.modalPanel.rawValue as CFString)),
    "Clipboard checks allow timer coalescing and keep running while menus and modals are open")
  app.togglePause()
  check(app.timer == nil, "Pausing stops clipboard checks")
  put(app, "copied while paused")
  app.togglePause()
  check(app.timer != nil && app.lastChange == app.board.changeCount,
    "Resuming restarts checks and skips what was copied while paused")
  app.suspend(true, reason: "display")
  check(app.timer == nil, "A sleeping display stops clipboard checks")
  app.suspend(false, reason: "display")
  check(app.timer != nil, "Waking the display resumes clipboard checks")

  let changesBefore = app.clipChanges
  put(app, String(repeating: "x", count: 1_048_577))
  app.poll()
  try await Task.sleep(nanoseconds: 100_000_000)
  check(app.clipChanges == changesBefore && app.pendingWrites == 0 && app.problem?.contains("1 MiB") == true,
    "Oversized copies are rejected before reaching storage")
  put(app, "fresh clip")
  app.poll()
  try await waitFor("A fresh clip was not captured") { app.clips.first?.text == "fresh clip" }
  let changes = app.clipChanges
  app.mutate { try $0.expire() }
  try await Task.sleep(nanoseconds: 100_000_000)
  check(app.clipChanges == changes, "A write that changes nothing refreshes neither menu nor bezel")
  check(app.expiryTimer.map {
      abs($0.fireDate.timeIntervalSince(app.clips[0].copied.addingTimeInterval(ClipLimits().age))) < 2
    } == true,
    "Expiry is scheduled for the oldest clip's real expiry time")
  app.mutate { try $0.add("stale", source: "", now: Date().addingTimeInterval(-ClipLimits().age - 5)) }
  try await waitFor("Stale fixture was not added") { app.clips.contains { $0.text == "stale" } }
  try await waitFor("An overdue clip did not expire") { !app.clips.contains { $0.text == "stale" } }
  check(app.clips.map(\.text) == ["fresh clip"] && app.expiryTimer != nil,
    "Overdue clips expire when due and the next expiry is re-armed")

  app.preparePopup()
  check(app.popup?.window?.isVisible == false && app.popup?.window?.alphaValue == 1
      && app.popup?.results.first?.text == "fresh clip",
    "The bezel is built and filled before the first shortcut without being shown")
  app.popup?.warmSource("com.apple.finder")
  let finder = app.popup?.sources["com.apple.finder"]
  check(finder?.name == "Finder" && finder?.icon?.representations.first is NSBitmapImageRep
      && finder?.icon?.size == NSSize(width: 28, height: 28),
    "Source app icons are resolved and rasterized before the bezel needs them")

  let quitting = makeApp("quit.sqlite")
  var quits = 0
  quitting.terminate = { quits += 1 }
  let quitURL = URL(string: "pos-clipboard://quit-if-idle")!
  check(quitting.isIdle, "A helper with nothing on screen and no paste pending is idle")
  quitting.application(NSApp, open: [quitURL])
  try await waitFor("quit-if-idle did not quit an idle helper") { quits == 1 }
  check(quitting.received && quitting.popup == nil && quitting.settings == nil,
    "quit-if-idle builds no UI and suppresses the launch-time history window")
  quitting.schedulePaste(
    expectedChange: quitting.board.changeCount, isDestinationReady: { false }, sendPaste: {})
  check(!quitting.isIdle, "A pending paste keeps the helper busy")
  quitting.application(NSApp, open: [quitURL])
  try await Task.sleep(nanoseconds: 50_000_000)
  check(quits == 1, "quit-if-idle does nothing while a paste is pending")
  // Cancel the pending paste before it gives up and beeps.
  quitting.deliver(Clip(id: "qa", text: "qa", source: "", copied: Date(), favorite: false), paste: false)
  check(quitting.isIdle, "Cancelling the paste makes the helper idle again")
  let cold = makeApp("cold.sqlite")
  cold.launched = false
  cold.terminate = { quits += 100 }
  cold.application(NSApp, open: [quitURL])
  try await Task.sleep(nanoseconds: 50_000_000)
  check(cold.quitAtLaunch && quits == 1, "quit-if-idle during launch quits before any menu or window exists")

  let agents = root.appendingPathComponent("LaunchAgents")
  let agent = agents.appendingPathComponent("com.productivity-os.clipboard-history.plist")
  let executable = "/Users/qa/Applications/Clipboard History.app/Contents/MacOS/ClipboardHistory"
  try ClipboardApp.writeLoginAgent(executable: executable, to: agent)
  let written = try PropertyListSerialization.propertyList(from: Data(contentsOf: agent), format: nil) as? NSDictionary
  let expected: NSDictionary = [
    "Label": "com.productivity-os.clipboard-history", "ProgramArguments": [executable, "--background"],
    "RunAtLoad": true, "KeepAlive": ["SuccessfulExit": false], "ProcessType": "Interactive",
    "ThrottleInterval": 30, "LimitLoadToSessionType": "Aqua",
  ]
  check(written == expected, "Start at login writes exactly the shared LaunchAgent contract")
  let linked = agents.appendingPathComponent("linked.plist")
  let elsewhere = root.appendingPathComponent("elsewhere.plist")
  try Data().write(to: elsewhere)
  try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: elsewhere)
  fails("Start at login refuses a symlinked registration") {
    try ClipboardApp.writeLoginAgent(executable: executable, to: linked)
  }
  print("Clipboard History resilience QA passed")
}
