import AppKit
import ApplicationServices
import Carbon

@MainActor final class LiveShelfQA {
  let root: URL
  let port: String
  let app = DropShelfApp()
  var shelf: ShelfController!
  var ownedWindows: [AXUIElement] = []
  var scriptWindowIDs: [String: String] = [:]
  var launchedApps: [NSRunningApplication] = []
  let previousApp = NSWorkspace.shared.frontmostApplication
  let previousPointer = CGEvent(source: nil)?.location
  var lines: [String] = []
  var incompleteScenarios = 0
  private var lastDestination = ""
  let eventSource = CGEventSource(stateID: .hidSystemState)
  init(root: URL, port: String) { self.root = root; self.port = port }
  func log(_ value: String) { lines.append(value); print(value); fflush(stdout) }
  func pause(_ milliseconds: UInt64) async { try? await Task.sleep(nanoseconds: milliseconds * 1_000_000) }
  func require(_ value: Bool, _ message: String) throws {
    guard value else { throw ShelfError(message) }; log("PASS: " + message)
  }
  func value(_ element: AXUIElement, _ attribute: CFString) -> CFTypeRef? {
    var result: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute, &result) == .success else { return nil }
    return result
  }
  func windows(_ process: NSRunningApplication) -> [AXUIElement] {
    value(AXUIElementCreateApplication(process.processIdentifier), kAXWindowsAttribute as CFString) as? [AXUIElement] ?? []
  }
  func text(_ element: AXUIElement, _ attribute: CFString) -> String { value(element, attribute) as? String ?? "" }
  func find(_ root: AXUIElement, matching needle: String) -> AXUIElement? {
    var queue: [(AXUIElement, Int)] = [(root, 0)], examined = 0
    while !queue.isEmpty && examined < 2200 {
      let (element, depth) = queue.removeFirst(); examined += 1
      for attribute in [kAXDescriptionAttribute, kAXTitleAttribute, kAXHelpAttribute] {
        if text(element, attribute as CFString) == needle { return element }
      }
      if depth < 18 {
        for child in value(element, kAXChildrenAttribute as CFString) as? [AXUIElement] ?? [] { queue.append((child, depth + 1)) }
      }
    }
    return nil
  }
  func center(_ element: AXUIElement) -> CGPoint? {
    guard let position = value(element, kAXPositionAttribute as CFString), let size = value(element, kAXSizeAttribute as CFString),
      CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
    var p = CGPoint.zero, s = CGSize.zero
    guard AXValueGetValue(position as! AXValue, .cgPoint, &p), AXValueGetValue(size as! AXValue, .cgSize, &s) else { return nil }
    return CGPoint(x: p.x + s.width / 2, y: p.y + s.height / 2)
  }
  func key(_ code: CGKeyCode, flags: CGEventFlags = []) {
    for down in [true, false] {
      let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)
      event?.flags = flags; event?.post(tap: .cghidEventTap)
    }
  }
  func type(_ string: String) {
    for unit in string.utf16 {
      for down in [true, false] {
        let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: down)
        var character = unit
        event?.keyboardSetUnicodeString(stringLength: 1, unicodeString: &character)
        event?.post(tap: .cghidEventTap)
      }
    }
  }
  func canAutomate(_ bundle: String) -> Bool {
    var target = AEAddressDesc()
    let bytes = Array(bundle.utf8)
    let created = bytes.withUnsafeBytes { AECreateDesc(typeApplicationBundleID, $0.baseAddress, $0.count, &target) }
    guard created == noErr else { return false }
    defer { AEDisposeDesc(&target) }
    return AEDeterminePermissionToAutomateTarget(&target, typeWildCard, typeWildCard, false) == noErr
  }
  func script(_ source: String) throws -> String {
    var error: NSDictionary?
    let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
    if let error { throw ShelfError("Owned-window scripting failed: \(error)") }
    return result?.stringValue ?? ""
  }
  func running(_ bundle: String, launch: Bool) async throws -> NSRunningApplication {
    if let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first { return running }
    guard launch, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) else { throw ShelfError("Application unavailable: \(bundle)") }
    let configuration = NSWorkspace.OpenConfiguration(); configuration.activates = false
    let result: NSRunningApplication = try await withCheckedThrowingContinuation { continuation in
      NSWorkspace.shared.openApplication(at: url, configuration: configuration) { app, error in
        if let app { continuation.resume(returning: app) } else { continuation.resume(throwing: error ?? ShelfError("Could not open application")) }
      }
    }
    launchedApps.append(result); return result
  }
  func newWindow(_ application: NSRunningApplication) async throws -> AXUIElement {
    let before = windows(application)
    application.activate(options: []); await pause(250)
    let bundle = application.bundleIdentifier ?? ""
    log("LIVE_APP bundle=\(bundle) front=\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "none") script_allowed=\(canAutomate(bundle))")
    if ["com.google.Chrome", "com.apple.Safari"].contains(bundle), canAutomate(bundle) {
      let command = bundle == "com.google.Chrome" ? "set qaWindow to make new window\nreturn id of qaWindow" : "make new document\nreturn id of front window"
      scriptWindowIDs[bundle] = try script("tell application id \"\(bundle)\"\n\(command)\nend tell")
      if let identifier = scriptWindowIDs[bundle] {
        log("LIVE_OWNED_WINDOW bundle=\(bundle) id=\(identifier)")
        _ = try script("tell application id \"\(bundle)\" to set bounds of window id \(identifier) to {40, 80, 700, 680}")
      }
    } else { key(45, flags: .maskCommand) }
    for _ in 0..<60 {
      await pause(75)
      if let window = windows(application).first(where: { candidate in !before.contains { CFEqual($0, candidate) } }) {
        ownedWindows.append(window)
        var origin = CGPoint(x: 40, y: 80), size = CGSize(width: 660, height: 600)
        AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, AXValueCreate(.cgPoint, &origin)!)
        AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, AXValueCreate(.cgSize, &size)!)
        await pause(150)
        return window
      }
    }
    throw ShelfError("Could not identify the newly created \(application.localizedName ?? "application") window")
  }
  func drag(from: CGPoint, to: CGPoint) async {
    let board = NSPasteboard(name: .drag), previous = NSPasteboard(name: .drag).changeCount
    CGEvent(mouseEventSource: eventSource, mouseType: .mouseMoved, mouseCursorPosition: from, mouseButton: .left)?.post(tap: .cghidEventTap)
    await pause(80)
    let down = CGEvent(mouseEventSource: eventSource, mouseType: .leftMouseDown, mouseCursorPosition: from, mouseButton: .left)
    down?.setIntegerValueField(.mouseEventClickState, value: 1); down?.post(tap: .cghidEventTap)
    await pause(130)
    for step in 1...35 {
      let fraction = CGFloat(step) / 35
      let point = CGPoint(x: from.x + (to.x - from.x) * fraction, y: from.y + (to.y - from.y) * fraction)
      CGEvent(mouseEventSource: eventSource, mouseType: .leftMouseDragged, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
      await pause(18)
    }
    await pause(180)
    log("LIVE_HOVER pasteboard_changed=\(board.changeCount != previous) types=\((board.types ?? []).map(\.rawValue)) mouse_appkit=\(NSEvent.mouseLocation) mouse_cg=\(String(describing: CGEvent(source: nil)?.location))")
    let up = CGEvent(mouseEventSource: eventSource, mouseType: .leftMouseUp, mouseCursorPosition: to, mouseButton: .left)
    up?.setIntegerValueField(.mouseEventClickState, value: 1); up?.post(tap: .cghidEventTap)
  }
  func orderShelf() {
    let bounds = NSScreen.main!.visibleFrame
    shelf.present(near: NSPoint(x: bounds.maxX - 300, y: bounds.midY), activate: false)
  }
  func diagnoseWindow(_ application: NSRunningApplication) {
    let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    let own = windows.first { ($0[kCGWindowNumber as String] as? Int) == shelf.window?.windowNumber }
    log("LIVE_SHELF on_screen=\(own != nil) frame=\(shelf.window!.frame)")
    guard let window = windows.first(where: { ($0[kCGWindowOwnerPID as String] as? Int32) == application.processIdentifier
      && ($0[kCGWindowName as String] as? String ?? "").hasPrefix("Drop Shelf Live QA") }),
      let number = window[kCGWindowNumber as String] as? Int else { log("LIVE_BROWSER_WINDOW no owned-title match in on-screen window list"); return }
    log("LIVE_BROWSER_WINDOW id=\(number) bounds=\(window[kCGWindowBounds as String] ?? "none")")
    if CGPreflightScreenCaptureAccess() {
      let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
      process.arguments = ["-x", "-l", String(number), root.appendingPathComponent("\(application.bundleIdentifier ?? "browser")-owned-window.png").path]
      try? process.run(); process.waitUntilExit()
    }
  }
  func shelfCenter() -> CGPoint {
    let frame = shelf.window!.frame
    return CGPoint(x: frame.midX, y: (NSScreen.screens.first?.frame.maxY ?? 0) - frame.midY)
  }
  func fixture() throws -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 128, pixelsHigh: 96, bitsPerSample: 8, samplesPerPixel: 4,
      hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    for y in 0..<96 { for x in 0..<128 {
      let offset = y * rep.bytesPerRow + x * 4
      rep.bitmapData![offset] = UInt8(x * 2); rep.bitmapData![offset + 1] = UInt8(y * 2)
      rep.bitmapData![offset + 2] = 190; rep.bitmapData![offset + 3] = 255
    } }
    let data = rep.representation(using: .png, properties: [:])!
    try data.write(to: root.appendingPathComponent("http/live-image.png"))
    let html = "<!doctype html><html><head><title>Drop Shelf Live QA</title></head><body style='margin:40px;background:#fff;font:20px system-ui'><h1>Drop Shelf Live QA</h1><p>Owned local test image</p><img style='position:fixed;left:80px;top:120px' alt='Drop Shelf QA image' draggable='true' width='320' height='240' src='/live-image.png'></body></html>"
    try Data(html.utf8).write(to: root.appendingPathComponent("http/index.html"))
    return data
  }
  func browser(_ bundle: String, original: Data, launch: Bool) async throws {
    let application = try await running(bundle, launch: launch)
    let window = try await newWindow(application)
    if let identifier = scriptWindowIDs[bundle] {
      let tab = bundle == "com.google.Chrome" ? "active tab" : "current tab"
      _ = try script("tell application id \"\(bundle)\" to set URL of \(tab) of window id \(identifier) to \"http://127.0.0.1:\(port)/index.html\"")
    } else {
      key(37, flags: .maskCommand); await pause(100)
      type("http://127.0.0.1:\(port)/index.html"); await pause(200); key(36)
    }
    var image: AXUIElement?
    for _ in 0..<15 {
      await pause(100)
      image = find(window, matching: "Drop Shelf QA image")
      if image != nil { break }
    }
    let source: CGPoint
    if let image, let actual = center(image) { source = actual }
    else if let identifier = scriptWindowIDs[bundle] {
      let property = bundle == "com.google.Chrome" ? "title of active tab" : "name of current tab"
      let title = try script("tell application id \"\(bundle)\" to return \(property) of window id \(identifier)")
      guard title == "Drop Shelf Live QA" else { throw ShelfError("Owned browser page did not load: \(title)") }
      // Fixed image spans x=120...440 and y≈256...528 in both browsers at these bounds.
      source = CGPoint(x: 280, y: 390)
      log("LIVE_IMAGE_POSITION fixed-owned-fixture (browser Accessibility tree unavailable)")
    } else {
      throw ShelfError("Browser does not expose the owned fixture image through Accessibility: \(bundle)")
    }
    let before = shelf.items.count
    orderShelf(); await pause(200); diagnoseWindow(application)
    log("LIVE_DRAG browser=\(bundle) source=\(source) destination=\(shelfCenter())")
    await drag(from: source, to: shelfCenter())
    let dropped = ProcessInfo.processInfo.systemUptime
    for _ in 0..<600 {
      if shelf.items.count > before && shelf.pendingImages == 0 { break }
      await pause(40)
    }
    try require(shelf.items.count == before + 1, "\(bundle) image arrives on its first drag (status: \(shelf.summaryLabel.stringValue))")
    let item = shelf.items.last!
    guard let url = item.resolvedURL() else { throw ShelfError("Browser item did not become a file") }
    let bytes = try Data(contentsOf: url)
    try require(item.kind == .image && item.owned && NSBitmapImageRep(data: bytes)?.pixelsWide == 128, "\(bundle) provides a real owned image")
    log("LIVE_RESULT browser=\(bundle) exact_bytes=\(bytes == original) completion_ms=\((ProcessInfo.processInfo.systemUptime - dropped) * 1000) filename=\(url.lastPathComponent)")
  }
  func finder() async throws {
    let application = try await running("com.apple.finder", launch: false)
    let folder = root.appendingPathComponent("DropShelf-Live-Output", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    if canAutomate("com.apple.finder") {
      application.activate(options: [])
      let identifier = try script("tell application id \"com.apple.finder\"\nset qaWindow to make new Finder window\nset target of qaWindow to POSIX file \"\(folder.path)\"\nset bounds of qaWindow to {40, 80, 700, 680}\nreturn id of qaWindow\nend tell")
      scriptWindowIDs["com.apple.finder"] = identifier
      log("LIVE_OWNED_WINDOW bundle=com.apple.finder id=\(identifier)")
      await pause(400)
      try require(try script("tell application id \"com.apple.finder\" to return name of window id \(identifier)") == folder.lastPathComponent,
        "Finder is showing only the owned output folder")
    } else {
      let window = try await newWindow(application)
      key(5, flags: [.maskCommand, .maskShift]); await pause(200); type(folder.path); await pause(200); key(36)
      for _ in 0..<50 {
        await pause(100)
        if text(window, kAXTitleAttribute as CFString) == folder.lastPathComponent { break }
      }
      try require(text(window, kAXTitleAttribute as CFString) == folder.lastPathComponent, "Finder is showing only the owned output folder")
    }
    orderShelf(); await pause(200)
    let expected = try shelf.items.compactMap { item -> Data? in try item.resolvedURL().map { try Data(contentsOf: $0) } }
    await drag(from: shelfCenter(), to: CGPoint(x: 450, y: 420))
    var files: [URL] = []
    for _ in 0..<100 {
      files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).filter { !$0.lastPathComponent.hasPrefix(".") }) ?? []
      if files.count == expected.count { break }
      await pause(50)
    }
    let bytes = try files.map { try Data(contentsOf: $0) }
    try require(bytes.count == expected.count && expected.allSatisfy { bytes.contains($0) }, "First drag from inactive shelf copies exact original image bytes into Finder")
    try require(shelf.items.allSatisfy { $0.resolvedURL().map { FileManager.default.fileExists(atPath: $0.path) } ?? false }, "Finder drag leaves shelf originals intact")
  }
  func cleanup() async {
    for (bundle, identifier) in scriptWindowIDs {
      _ = try? script("tell application id \"\(bundle)\" to close window id \(identifier)")
    }
    for window in ownedWindows.reversed() {
      if let button = value(window, kAXCloseButtonAttribute as CFString), CFGetTypeID(button) == AXUIElementGetTypeID() {
        AXUIElementPerformAction(button as! AXUIElement, kAXPressAction as CFString)
      }
    }
    shelf?.closePreview(); shelf?.window?.orderOut(nil)
    if let previousPointer { CGWarpMouseCursorPosition(previousPointer) }
    await pause(150)
    // These processes were not running before this harness started them.
    for application in launchedApps { application.terminate() }
    previousApp?.activate(options: [])
    try? Data((lines.joined(separator: "\n") + "\n").utf8).write(to: root.appendingPathComponent("live-results.log"))
  }
  func run() async throws {
    log("LIVE_PREFLIGHT accessibility=\(AXIsProcessTrusted()) event_post=\(CGPreflightPostEventAccess())")
    guard AXIsProcessTrusted(), CGPreflightPostEventAccess() else { throw ShelfError("Live QA blocked: existing Accessibility/event-post permission is unavailable; no permission was requested or changed.") }
    let original = try fixture()
    app.store = try ShelfStore(root: root.appendingPathComponent("store"))
    let id = try app.store!.create(); shelf = ShelfController(app: app, id: id); app.controllers[id] = shelf
    shelf.rootView?.dragObserver = { [weak self] phase, types, mask in
      guard let self else { return }
      let event = "LIVE_DESTINATION phase=\(phase) mask=\(mask) types=\(types)"
      if event != self.lastDestination { self.lastDestination = event; self.log(event) }
    }
    orderShelf()
    do { try await browser("com.google.Chrome", original: original, launch: false) }
    catch { incompleteScenarios += 1; log("CHROME_LIMITATION: \(error.localizedDescription)") }
    if shelf.items.isEmpty {
      try await app.withStore { store in try store.add([ShelfItem.file(self.root.appendingPathComponent("http/live-image.png"))], to: id) }
      shelf.render()
    }
    do { try await finder() } catch { incompleteScenarios += 1; log("FINDER_LIMITATION: \(error.localizedDescription)") }
    do { try await browser("com.apple.Safari", original: original, launch: true) }
    catch { incompleteScenarios += 1; log("SAFARI_LIMITATION: \(error.localizedDescription)") }
    await app.waitForStore()
    guard incompleteScenarios == 0 else { throw ShelfError("\(incompleteScenarios) live scenarios remain unverified; see the diagnostic log.") }
    log("LIVE_QA_PASSED")
  }
}

@main struct LiveShelfMain {
  @MainActor static func main() {
    NSApplication.shared.setActivationPolicy(.accessory)
    let qa = LiveShelfQA(root: URL(fileURLWithPath: CommandLine.arguments[1]), port: CommandLine.arguments[2])
    Task { @MainActor in
      var status: Int32 = 0
      do { try await qa.run() } catch { qa.log("LIVE_QA_FAILED: " + error.localizedDescription); status = 1 }
      await qa.cleanup(); exit(status)
    }
    NSApp.run()
  }
}
