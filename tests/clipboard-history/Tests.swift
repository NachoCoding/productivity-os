import AppKit
import CryptoKit
import SQLite3
@MainActor func allSubviews(_ view: NSView) -> [NSView] { view.subviews + view.subviews.flatMap(allSubviews) }

func check(_ result: @autoclosure () throws -> Bool, _ message: String) {
  do {
    if try result() {
      print("PASS \(message)")
      return
    }
  } catch { fputs("\(error)\n", stderr) }
  fputs("FAIL \(message)\n", stderr)
  exit(1)
}
func fails(_ message: String, _ work: () throws -> Void) {
  do {
    try work()
    check(false, message)
  } catch { print("PASS \(message)") }
}
func sql(_ url: URL, _ command: String) throws {
  var db: OpaquePointer?
  guard sqlite3_open(url.path, &db) == SQLITE_OK else { throw ClipError("fixture open") }
  defer { sqlite3_close(db) }
  guard sqlite3_exec(db, command, nil, nil, nil) == SQLITE_OK else {
    throw ClipError("fixture SQL")
  }
}
func footprint() -> UInt64 {
  var usage = rusage_info_v2()
  let status = withUnsafeMutablePointer(to: &usage) {
    $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
      proc_pid_rusage(getpid(), RUSAGE_INFO_V2, $0)
    }
  }
  return status == 0 ? usage.ri_phys_footprint : 0
}
@main struct Tests {
  @MainActor static func main() {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    Task { @MainActor in
      do { try await run(); exit(0) }
      catch { fputs("FAIL: \(error)\n", stderr); exit(1) }
    }
    app.run()
  }
  @MainActor static func run() async throws {
    setbuf(stdout, nil)
    _ = NSApplication.shared
    let root = URL(fileURLWithPath: CommandLine.arguments[1])
    let key = SymmetricKey(size: .bits256)
    let url = root.appendingPathComponent("history.sqlite")
    let store = try ClipStore(url: url, key: key)
    let exact = "  func café() {\n\tprint(\"🙂\")\n}\n\n  "
    try store.add(exact, source: "org.test.source")
    check(
      store.clips[0].text == exact, "Unicode, whitespace, tabs, and trailing lines remain exact")
    try store.add("second", source: "org.test.other")
    try store.add(exact, source: "org.test.source")
    check(
      store.clips.count == 2 && store.clips.first?.text == exact,
      "Exact duplicates move to top without duplicating")
    check(ClipboardPolicy.matches(store.clips[0], query: "CAFÉ"), "Search is case insensitive")
    check(
      ClipboardPolicy.matches(store.clips[0], query: "org.test.source"),
      "Search includes source identifier")
    check(store.clips[0].text == exact, "Searching does not transform source text")
    try store.add("", source: "")
    check(store.clips.count == 2, "Empty clipboard ignored")
    let persisted = try ClipStore(url: url, key: key)
    check(persisted.clips == store.clips, "Encrypted history survives reopen")
    let bytes = try Data(contentsOf: url)
    check(
      bytes.range(of: Data(exact.utf8)) == nil
        && bytes.range(of: Data("org.test.source".utf8)) == nil,
      "SQLite contains neither plaintext clips nor source labels")
    fails("Incorrect encryption key fails without replacing history") {
      _ = try ClipStore(url: url, key: SymmetricKey(size: .bits256))
    }
    check(try ClipStore(url: url, key: key).clips == store.clips, "History intact after wrong key")
    let saved = store.clips
    try sql(
      url,
      "CREATE TRIGGER reject_insert BEFORE INSERT ON clips BEGIN SELECT RAISE(ABORT,'test'); END;")
    fails("Storage failure is reported") { try store.add("unsaved", source: "") }
    check(store.clips == saved, "Failed write preserves in-memory history")
    try sql(url, "DROP TRIGGER reject_insert")
    try store.add("recovered", source: "")
    check(store.clips.first?.text == "recovered", "Writes recover after storage failure")
    fails("Overlarge entry is rejected") {
      try store.add(String(repeating: "x", count: 1_048_577), source: "")
    }
    check(store.clips.first?.text == "recovered", "Rejected entry does not evict history")
    for marker in ClipboardPolicy.ignored {
      check(
        !ClipboardPolicy.accepts(
          types: ["public.utf8-plain-text", marker], source: "", foreground: "", excluded: []),
        "Skip marker \(marker)")
    }
    check(
      !ClipboardPolicy.accepts(
        types: [], source: "excluded", foreground: "other", excluded: ["excluded"]),
      "Exclude declared source app")
    check(
      !ClipboardPolicy.accepts(
        types: [], source: "other", foreground: "excluded", excluded: ["excluded"]),
      "Exclude foreground app even with a different source marker")
    check(
      ClipboardPolicy.accepts(
        types: ["public.utf8-plain-text"], source: "org.editor", foreground: "org.editor",
        excluded: []), "Ordinary code copy accepted")
    let limited = try ClipStore(
      url: root.appendingPathComponent("limits.sqlite"), key: key,
      limits: ClipLimits(ordinary: 2, favorites: 1, itemBytes: 100, totalBytes: 15, age: 60))
    try limited.add("favorite", source: "")
    try limited.favorite(limited.clips[0].id)
    try limited.add("one", source: "")
    try limited.add("two", source: "")
    try limited.add("tri", source: "")
    check(
      limited.clips.contains { $0.text == "favorite" }
        && !limited.clips.contains { $0.text == "one" },
      "Capacity evicts oldest ordinary clip and protects favorites")
    fails("Favorite count cap enforced") { try limited.favorite(limited.clips[0].id) }
    let before = limited.clips
    fails("Full favorites reject incoming item transactionally") {
      try limited.add("12345678", source: "")
    }
    check(limited.clips == before, "Failed capacity reservation preserves existing entries")
    try limited.expire(now: Date().addingTimeInterval(100))
    check(
      limited.clips.count == 1 && limited.clips[0].favorite,
      "Expiry deletes ordinary clips but preserves favorites")
    try limited.add("recent", source: "")
    try limited.clear(includeFavorites: false)
    check(
      limited.clips.count == 1 && limited.clips[0].favorite, "Clear preserves favorites by default")
    try limited.clear(includeFavorites: true)
    check(limited.clips.isEmpty, "Explicit clear deletes favorites too")
    let link = root.appendingPathComponent("link.sqlite")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: url)
    fails("Storage symlinks rejected") { _ = try ClipStore(url: link, key: key) }
    let malformed = root.appendingPathComponent("malformed.sqlite")
    try FileManager.default.copyItem(at: url, to: malformed)
    try sql(malformed, "UPDATE clips SET payload=x'000102'")
    let unreadable = try ClipStore(url: malformed, key: key)
    check(unreadable.clips.isEmpty && unreadable.skipped == store.clips.count,
      "Corrupt ciphertext is skipped and counted instead of blocking history")
    try await runClipboardResilienceTests(root: root)

    let app = ClipboardApp()
    check(
      app.validDestination(NSRunningApplication.current) == nil,
      "Never paste into the clipboard helper itself")
    check(app.validDestination(nil) == nil, "Missing destination uses copy-only fallback")
    if let raycast = NSRunningApplication.runningApplications(
      withBundleIdentifier: "com.raycast.macos"
    ).first {
      check(
        app.validDestination(raycast) == nil, "Cold Raycast launch never pastes back into Raycast")
    }
    let suite = "com.productivity-os.clipboard-qa." + UUID().uuidString
    app.defaults = UserDefaults(suiteName: suite)!
    defer { app.defaults.removePersistentDomain(forName: suite) }
    app.board = NSPasteboard(name: NSPasteboard.Name("clipboard-qa-" + UUID().uuidString))
    defer { app.board.releaseGlobally() }
    app.clips = try await app.worker.open(
      url: root.appendingPathComponent("monitor.sqlite"), key: key)
    app.ready = true
    app.lastChange = app.board.changeCount
    func put(_ text: String, marker: String? = nil) {
      let item = NSPasteboardItem()
      item.setString(text, forType: .string)
      if let marker { item.setData(Data(), forType: NSPasteboard.PasteboardType(marker)) }
      app.board.clearContents()
      app.board.writeObjects([item])
    }
    func settle() async throws { try await Task.sleep(nanoseconds: 150_000_000) }
    put(exact)
    app.poll()
    try await settle()
    check(
      app.clips.count == 1 && app.clips[0].text == exact,
      "Native pasteboard monitoring captures exact text")
    app.poll()
    try await settle()
    check(app.clips.count == 1, "Unchanged clipboard is not captured again")
    put("do-not-store", marker: "org.nspasteboard.ConcealedType")
    app.poll()
    try await settle()
    check(app.clips.count == 1, "Concealed native pasteboard content never reaches storage")
    app.togglePause()
    put("paused")
    app.poll()
    app.togglePause()
    app.poll()
    try await settle()
    check(app.clips.count == 1, "Pause and resume never backfill paused clipboard")
    app.suspend(true, reason: "lock")
    app.suspend(true, reason: "sleep")
    app.suspend(false, reason: "sleep")
    check(app.suspended, "Waking does not resume collection while screen remains locked")
    put("locked")
    app.poll()
    app.suspend(false, reason: "lock")
    app.poll()
    try await settle()
    check(app.clips.count == 1, "Unlock never imports clipboard copied while locked")
    app.deliver(app.clips[0], paste: false)
    app.poll()
    try await settle()
    check(
      app.board.string(forType: .string) == exact && app.clips.count == 1,
      "Copy action preserves full text and suppresses self recapture")
    app.popup = ClipboardPopup(app: app)
    app.popup?.show()
    try await settle()
    check(app.popup?.window?.isKeyWindow == true && app.popup?.window?.isVisible == true, "Bezel stays visible and receives keyboard focus")
    check(app.popup?.results.count == 1, "Popup displays stored entries")
    let bezel = app.popup!
    check(bezel.window!.styleMask.contains(.titled) == false && !bezel.window!.isOpaque,
      "Flycut bezel is borderless and nonopaque")
    check(bezel.window!.backgroundColor.alphaComponent == 0 && bezel.window!.alphaValue == 1,
      "Window background is transparent while text stays opaque")
    check(!bezel.preview.drawsBackground && bezel.search.isHidden,
      "Single clip preview has no opaque background or always-visible search")
    check(bezel.counter.stringValue == "1 of 1", "Bezel shows current clip position")
    bezel.move(1)
    bezel.move(-1)
    check(bezel.selected?.text == exact, "Navigation wraps safely at both ends")
    let secondClip = Clip(id: "bezel-test-second", text: "second preview", source: "org.test", copied: Date(), favorite: true)
    bezel.results.append(secondClip)
    bezel.move(1)
    check(bezel.selected?.id == secondClip.id && bezel.counter.stringValue == "2 of 2"
      && bezel.preview.string == secondClip.text && bezel.source.stringValue.hasPrefix("★"),
      "Navigation updates text, favorite marker, and position together")
    bezel.move(-1)
    check(bezel.preview.string == exact, "Previous clip restores exact preview")
    bezel.refresh()
    // Menu/Raycast browsing must not paste merely because a modifier is released.
    let tapChange = app.board.changeCount
    bezel.modifiersChanged([])
    check(app.board.changeCount == tapChange && bezel.window?.isVisible == true && !bezel.holding,
      "Releasing modifiers during ordinary browsing keeps the bezel open without pasting")
    let typed = NSEvent.keyEvent(
      with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
      windowNumber: bezel.window!.windowNumber, context: nil, characters: "c",
      charactersIgnoringModifiers: "c", isARepeat: false, keyCode: 8)!
    check(app.handleKey(typed) == nil && !bezel.search.isHidden && bezel.search.stringValue == "c",
      "Typing a character starts inline search with that character")
    check(!bezel.search.isBezeled && !bezel.search.isBordered && !bezel.search.drawsBackground,
      "Inline search draws no field border or background")
    bezel.endSearch()
    check(bezel.search.isHidden && bezel.search.stringValue.isEmpty, "Search can be cleared")
    let bordered = (bezel.window?.contentView.map { allSubviews($0) } ?? []).filter {
      ($0 as? NSButton)?.isBordered == true || ($0 as? NSScrollView)?.borderType != nil && ($0 as! NSScrollView).borderType != .noBorder
        || ($0 as? NSScrollView)?.hasVerticalScroller == true
    }
    check(bordered.isEmpty, "Bezel contains no bordered buttons, scroll borders, or scrollers")

    app.popup?.search.stringValue = "not-present"
    app.popup?.refresh()
    check(app.popup?.results.isEmpty == true, "Popup filters empty search results safely")
    check(bezel.counter.stringValue == "Empty" && bezel.preview.string.hasPrefix("No matching clips."),
      "Empty filter clears stale preview and position")
    bezel.search.stringValue = ""
    bezel.favoriteOnly.state = .on
    bezel.refresh()
    check(bezel.preview.string.contains("No favorites yet"), "Empty favorites explains how to save a favorite")
    bezel.favoriteOnly.state = .off
    app.popup?.search.stringValue = "CAFÉ"
    app.popup?.refresh()
    check(app.popup?.results.count == 1, "Popup search finds Unicode text")
    app.popup?.window?.contentView?.layoutSubtreeIfNeeded()
    if let view = app.popup?.window?.contentView,
      let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)
    {
      view.cacheDisplay(in: view.bounds, to: rep)
      try rep.representation(using: .png, properties: [:])?.write(
        to: root.appendingPathComponent("popup.png"))
    }
    check(
      app.popup?.window?.contentView?.hasAmbiguousLayout == false, "Popup has determinate layout")
    let oldChange = app.board.changeCount
    let escape = NSEvent.keyEvent(
      with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
      windowNumber: app.popup!.window!.windowNumber, context: nil, characters: "",
      charactersIgnoringModifiers: "", isARepeat: false, keyCode: 53)!
    _ = app.handleKey(escape)
    check(app.board.changeCount == oldChange, "Escape does not mutate clipboard")
    app.popup?.window?.close()
    app.showSettings()
    app.defaults.set(["org.test.passwords"], forKey: "excluded")
    app.showSettings()
    check(
      app.exclusions?.string == "org.test.passwords",
      "Settings reloads saved app exclusions on every open")
    app.settings?.close()

    // A real paste targets only our dedicated editor process. Never send keystrokes to a terminal.
    if ProcessInfo.processInfo.environment["QA_LIVE_PASTE"] == "1" && AXIsProcessTrusted() {
      let general = NSPasteboard.general
      let initialCounter = general.changeCount
      var original: [NSPasteboardItem] = []
      var snapshotBytes = 0
      var snapshotComplete = true
      for item in general.pasteboardItems ?? [] {
        let saved = NSPasteboardItem()
        for type in item.types {
          guard let data = item.data(forType: type) else {
            snapshotComplete = false
            break
          }
          snapshotBytes += data.count
          if snapshotBytes > 4 * 1_048_576 {
            snapshotComplete = false
            break
          }
          saved.setData(data, forType: type)
        }
        original.append(saved)
        if !snapshotComplete { break }
      }
      if snapshotComplete && general.changeCount == initialCounter {
        let fixture = Process()
        fixture.executableURL = root.appendingPathComponent(
          "PasteFixture.app/Contents/MacOS/PasteFixture")
        fixture.arguments = [root.path]
        try fixture.run()
        defer { if fixture.isRunning { fixture.terminate() } }
        let deadline = Date().addingTimeInterval(8)
        while !FileManager.default.fileExists(
          atPath: root.appendingPathComponent("paste-ready").path) && Date() < deadline
        { try await Task.sleep(nanoseconds: 50_000_000) }
        guard let target = NSRunningApplication(processIdentifier: fixture.processIdentifier) else {
          throw ClipError("Owned paste target unavailable")
        }
        check(
          target.bundleIdentifier == "com.productivity-os.clipboard-qa-fixture",
          "Live paste destination is the owned fixture")
        let privateBoard = app.board
        app.board = general
        app.destination = target
        defer { app.board = privateBoard }
        let clip = Clip(
          id: "fixture", text: "Clipboard QA: owned fixture\n\tUnicode café 🙂  ",
          source: "com.productivity-os.clipboard-qa-fixture", copied: Date(), favorite: false)
        app.deliver(clip, paste: true)
        let ownedCounter = app.lastChange
        while !FileManager.default.fileExists(
          atPath: root.appendingPathComponent("paste-passed").path) && Date() < deadline
        { try await Task.sleep(nanoseconds: 50_000_000) }
        let pasted = FileManager.default.fileExists(
          atPath: root.appendingPathComponent("paste-passed").path)
        if general.changeCount == ownedCounter {
          general.clearContents()
          general.writeObjects(original)
        }
        if fixture.isRunning { fixture.terminate() }
        check(pasted, "Real focus restoration and ⌘V paste preserve multiline Unicode text")
      } else {
        print("SKIP live paste: clipboard changed or could not be preserved within 4 MiB")
      }
    } else {
      print("SKIP live paste: opt in with QA_LIVE_PASTE=1 and Accessibility permission")
    }

    try autoreleasepool {
      let stress = try ClipStore(url: root.appendingPathComponent("stress.sqlite"), key: key)
      let startFootprint = footprint()
      for n in 0..<650 {
        try stress.add(
          "fixture-\(n) " + String(repeating: "code \t line\n", count: 1300),
          source: "org.test.editor")
      }
      check(stress.clips.count == 500, "650 copies retain only the configured 500 ordinary entries")
      var times: [Double] = []
      for _ in 0..<20 {
        let start = ProcessInfo.processInfo.systemUptime
        let matches = stress.clips.filter { ClipboardPolicy.matches($0, query: "fixture-640") }
        check(matches.count == 1, "Bounded history search result is correct")
        times.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
      }
      check(times.max()! < 150, "500-entry search stays below 150 ms")
      let peak = footprint()
      print(
        "PERFORMANCE search_ms=\(times.max()!) footprint_MiB=\(peak/1_048_576) growth_MiB=\((peak > startFootprint ? peak-startFootprint : 0)/1_048_576)"
      )
      try stress.clear(includeFavorites: true)
      check(
        try ClipStore(url: root.appendingPathComponent("stress.sqlite"), key: key).clips.isEmpty,
        "Stress history stays deleted after reopen")
    }
    try await runClipboardShortcutTests()
    try await runClipboardDelayedPasteTests()
    try Data("complete".utf8).write(to: root.appendingPathComponent("qa-complete"))
    print("Clipboard History native QA passed")
  }
}
