import AppKit
import ApplicationServices
import ScreenCaptureKit

struct CaptureTarget {
  var display: SCDisplay
  var rect: CGRect  // display-local top-left points
  var window: SCWindow?
  var scale: CGFloat
}

@MainActor private final class Once<T> {
  var continuation: CheckedContinuation<T, Error>?
  init(_ continuation: CheckedContinuation<T, Error>) { self.continuation = continuation }
  func resume(_ result: Result<T, Error>) {
    continuation?.resume(with: result)
    continuation = nil
  }
}

/// Returns or throws within `seconds` even if `work` never answers (a wedged ScreenCaptureKit call).
/// Abandoned work finishes on its own and its result is dropped.
@MainActor func withDeadline<T>(
  _ seconds: Double, _ work: @escaping @MainActor () async throws -> T
) async throws -> T {
  try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
    let once = Once(continuation)
    let timer = Task { @MainActor in
      try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
      once.resume(.failure(StudioError("Screen capture did not respond. Try again.")))
    }
    Task { @MainActor in
      do { once.resume(.success(try await work())) } catch { once.resume(.failure(error)) }
      timer.cancel()
    }
  }
}

@MainActor final class CaptureEngine {
  var overlays: [NSWindow] = []
  var selection: CheckedContinuation<CaptureTarget?, Never>?
  var content: SCShareableContent?
  var windowOrder: [CGWindowID: Int] = [:]
  var windowMode = false
  var last: CaptureTarget?
  var frozenSelection: CGImage?
  var fixedSize: CGSize?
  var ratio: CGFloat?
  /// Bumped per selection; preparation work that outlives its selection (timed out, cancelled) is dropped.
  private(set) var generation = 0
  /// ⌘⇧2 must never wedge: a selector with no overlay on screen by then is abandoned.
  var preparationTimeout = 3.0
  /// Test seams: overlay preparation, the non-modal timeout notice and error reports.
  var prepare: (@MainActor (CaptureEngine, Int) async throws -> Void)?
  var notice: @MainActor (String) -> Void = { StudioApp.shared.notify($0) }
  var report: @MainActor (Error) -> Void = { StudioApp.shared.report($0) }
  var showsCursor: Bool { UserDefaults.standard.bool(forKey: "cursor") }
  func available(onScreenOnly: Bool = true) async throws -> SCShareableContent {
    guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
      Self.openScreenRecordingSettings()
      throw StudioError(
        "Turn on Screenshot Studio in the Screen & System Audio Recording list that just opened, then choose Quit & Reopen."
      )
    }
    do {
      return try await withDeadline(10) {
        try await SCShareableContent.excludingDesktopWindows(
          false, onScreenWindowsOnly: onScreenOnly)
      }
    } catch let error as StudioError {
      throw error  // timed out: macOS did not refuse anything
    } catch {
      // A rebuilt app can pass the preflight with a stale grant yet still be refused here.
      Self.openScreenRecordingSettings()
      throw StudioError(
        "macOS refused screen access. Switch Screenshot Studio off and on in the list that just opened, then choose Quit & Reopen."
      )
    }
  }
  static func openScreenRecordingSettings() {
    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
      NSWorkspace.shared.open(url)
    }
  }
  func filter(_ target: CaptureTarget, content: SCShareableContent) -> SCContentFilter {
    if let window = target.window { return SCContentFilter(desktopIndependentWindow: window) }
    return SCContentFilter(
      display: target.display,
      excludingApplications: content.applications.filter { $0.processID == getpid() },
      exceptingWindows: [])
  }
  func configuration(_ target: CaptureTarget) -> SCStreamConfiguration {
    let config = SCStreamConfiguration()
    config.width = Int(target.rect.width * target.scale)
    config.height = Int(target.rect.height * target.scale)
    if target.window == nil { config.sourceRect = target.rect }
    config.showsCursor = showsCursor
    config.captureResolution = .best
    config.ignoreShadowsSingleWindow = !UserDefaults.standard.bool(forKey: "shadow")
    config.colorSpaceName = CGColorSpace.sRGB
    return config
  }
  func capture(_ target: CaptureTarget) async throws -> CGImage {
    let current = try await available(onScreenOnly: target.window == nil)
    guard current.displays.contains(where: { $0.displayID == target.display.displayID }) else {
      throw StudioError("The selected display disconnected. Capture again.")
    }
    if let window = target.window,
      !current.windows.contains(where: { $0.windowID == window.windowID })
    {
      throw StudioError("The selected window is no longer available")
    }
    let filter = filter(target, content: current)
    let config = configuration(target)
    let image = try await withDeadline(10) {
      try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }
    try Limits.validate(CGSize(width: image.width, height: image.height))
    return image
  }
  /// Front-to-back on-screen window numbers. Read off the main thread; window mode uses it to pick
  /// the topmost window under the pointer.
  nonisolated static func stackOrder() -> [CGWindowID: Int] {
    let windows =
      CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
      as? [[String: Any]] ?? []
    return Dictionary(
      windows.enumerated().compactMap { index, info in
        (info[kCGWindowNumber as String] as? UInt32).map { ($0, index) }
      }, uniquingKeysWith: { a, _ in a })
  }
  static func displayID(_ screen: NSScreen) -> UInt32? {
    screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32
  }
  static func pointerScreen() -> NSScreen? {
    let mouse = NSEvent.mouseLocation
    return NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
      ?? NSScreen.screens.first
  }
  func choose(mode: String = "capture") async throws -> CaptureTarget? {
    if let values = UserDefaults.standard.array(forKey: "fixedCapture") as? [Double],
      values.count == 2
    {
      fixedSize = CGSize(width: values[0], height: values[1])
    }
    let savedRatio = UserDefaults.standard.double(forKey: "captureRatio")
    ratio = savedRatio > 0 ? savedRatio : nil
    frozenSelection = nil
    guard mode == "repeat" || mode == "display" else {
      return await select(windowMode: mode == "window")
    }
    let current = try await available()
    content = current
    if mode == "repeat" {
      if let last { return last }
      if let saved = UserDefaults.standard.dictionary(forKey: "lastCapture"),
        let id = saved["display"] as? UInt32,
        let d = current.displays.first(where: { $0.displayID == id }),
        let coords = saved["rect"] as? [Double], coords.count == 4
      {
        let r = CGRect(x: coords[0], y: coords[1], width: coords[2], height: coords[3])
        let window = (saved["window"] as? UInt32).flatMap { id in
          current.windows.first { $0.windowID == id }
        }
        if saved["window"] != nil && window == nil {
          throw StudioError("The previous window has closed. Select another window.")
        }
        let scale =
          NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32) == id
          }?.backingScaleFactor ?? 1
        guard r.width > 0, r.height > 0,
          window != nil || CGRect(x: 0, y: 0, width: d.width, height: d.height).contains(r)
        else { throw StudioError("Display layout changed. Select a new area.") }
        return CaptureTarget(display: d, rect: r, window: window, scale: scale)
      }
      throw StudioError("Capture an area first before using Capture Previous Area.")
    }
    guard let screen = Self.pointerScreen(), let screenID = Self.displayID(screen),
      let display = current.displays.first(where: { $0.displayID == screenID })
    else { throw StudioError("No display is available") }
    let t = CaptureTarget(
      display: display, rect: CGRect(x: 0, y: 0, width: display.width, height: display.height),
      scale: screen.backingScaleFactor)
    last = t
    return t
  }
  /// Shows a frozen selector on every display; nil means cancelled, failed (reported) or timed out.
  /// The continuation is registered before any await, so a second ⌘⇧2 sees the selection at once.
  func select(windowMode window: Bool) async -> CaptureTarget? {
    guard selection == nil else { return nil }
    generation += 1
    let token = generation
    windowMode = window
    windowOrder = [:]
    content = nil
    return await withCheckedContinuation { continuation in
      selection = continuation
      DispatchQueue.main.asyncAfter(deadline: .now() + preparationTimeout) { [weak self] in
        self?.preparationExpired(token)
      }
      Task { [weak self] in
        guard let self else { return }
        do {
          if let prepare { try await prepare(self, token) } else { try await prepareOverlays(token) }
          if isCurrent(token), overlays.isEmpty { throw StudioError("No display is available") }
        } catch {
          guard isCurrent(token) else { return }  // already timed out (and reported once)
          finish(nil)
          report(error)
        }
      }
    }
  }
  func isCurrent(_ token: Int) -> Bool { token == generation && selection != nil }
  func preparationExpired(_ token: Int) {
    guard isCurrent(token), overlays.isEmpty else { return }
    finish(nil)
    notice("Screen capture did not respond in time. Try again.")
  }
  /// Captures every display's frozen background concurrently, the display under the pointer first,
  /// and shows each selector as soon as its image is ready (no selector is visible in any capture:
  /// each covers only its own display).
  func prepareOverlays(_ token: Int) async throws {
    let current = try await available()
    guard isCurrent(token) else { return }
    content = current
    let order = Task.detached(priority: .userInitiated) { CaptureEngine.stackOrder() }
    Task { [weak self] in
      let value = await order.value
      if let self, isCurrent(token) { windowOrder = value }
    }
    let pointer = Self.pointerScreen()
    let screens = NSScreen.screens.filter { $0 === pointer } + NSScreen.screens.filter { $0 !== pointer }
    let jobs: [(screen: NSScreen, display: SCDisplay)] = screens.compactMap { screen in
      guard let id = Self.displayID(screen),
        let display = current.displays.first(where: { $0.displayID == id })
      else { return nil }
      return (screen, display)
    }
    var failure: Error?
    await withTaskGroup(of: (Int, Result<CGImage, Error>).self) { group in
      for (index, job) in jobs.enumerated() {
        let t = CaptureTarget(
          display: job.display,
          rect: CGRect(x: 0, y: 0, width: job.display.width, height: job.display.height),
          scale: job.screen.backingScaleFactor)
        let filter = filter(t, content: current)
        let config = configuration(t)
        group.addTask {
          do {
            return (
              index,
              .success(
                try await SCScreenshotManager.captureImage(
                  contentFilter: filter, configuration: config))
            )
          } catch { return (index, .failure(error)) }
        }
      }
      for await (index, result) in group {
        guard isCurrent(token) else {
          group.cancelAll()
          return
        }
        switch result {
        case .success(let image):
          // Window mode hit-tests by z-order from the first pointer move.
          if windowMode, windowOrder.isEmpty {
            let value = await order.value
            guard isCurrent(token) else {
              group.cancelAll()
              return
            }
            windowOrder = value
          }
          showOverlay(jobs[index].screen, jobs[index].display, image, key: jobs[index].screen === pointer)
        case .failure(let error): failure = failure ?? error
        }
      }
    }
    if isCurrent(token), overlays.isEmpty, let failure { throw failure }
  }
  func showOverlay(_ screen: NSScreen, _ display: SCDisplay, _ image: CGImage, key: Bool) {
    let window = SelectorWindow(
      contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
    window.level = .screenSaver
    window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    window.isReleasedWhenClosed = false
    let view = SelectionView(
      frame: CGRect(origin: .zero, size: screen.frame.size), image: image, display: display,
      screen: screen, engine: self)
    window.contentView = view
    window.makeFirstResponder(view)
    let first = overlays.isEmpty
    overlays.append(window)
    // The pointer's display takes keyboard focus; until it appears, the first selector does (Esc works).
    if key || first { window.makeKeyAndOrderFront(nil) } else { window.orderFront(nil) }
    if first { NSApp.activate(ignoringOtherApps: true) }
  }
  func refreshOverlays() {
    for window in overlays { (window.contentView as? SelectionView)?.refreshOverlay() }
  }
  func finish(_ target: CaptureTarget?) {
    for window in overlays {
      window.orderOut(nil)
      window.close()
    }
    overlays.removeAll()
    if let target {
      last = target
      var saved: [String: Any] = [
        "display": target.display.displayID,
        "rect": [target.rect.minX, target.rect.minY, target.rect.width, target.rect.height],
      ]
      if let window = target.window { saved["window"] = window.windowID }
      UserDefaults.standard.set(saved, forKey: "lastCapture")
    }
    let c = selection
    selection = nil
    c?.resume(returning: target)
  }
}

final class SelectorWindow: NSWindow { override var canBecomeKey: Bool { true } }

/// Click-through, non-drawing pieces of the selector overlay (a line, or a framed rectangle).
@MainActor final class OverlayShape: NSView {
  private var fill: NSColor?, border: NSColor?, borderWidth: CGFloat = 0
  /// Applied at once as well: a hidden or not-yet-shown view may get no display pass before it appears.
  func style(fill: NSColor? = nil, border: NSColor? = nil, width: CGFloat = 0) {
    self.fill = fill
    self.border = border
    borderWidth = width
    wantsLayer = true
    updateLayer()
  }
  override var wantsUpdateLayer: Bool { true }
  override func updateLayer() {
    layer?.backgroundColor = fill?.cgColor
    layer?.borderColor = border?.cgColor
    layer?.borderWidth = borderWidth
  }
  override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
@MainActor final class OverlayLabel: NSTextField {
  override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

@MainActor final class SelectionView: NSView {
  let image: CGImage, display: SCDisplay, screen: NSScreen
  unowned let engine: CaptureEngine
  var start: CGPoint?, point = CGPoint.zero, selected: CGRect?
  var selectedWindow: SCWindow?
  // The frozen image is this layer's contents, composited once. Pointer moves only reposition these
  // small overlay views, never redraw the full-resolution image.
  let crossV = OverlayShape(), crossH = OverlayShape(), halo = OverlayShape(), outline = OverlayShape()
  let sizeLabel = OverlayLabel(labelWithString: ""), hint = OverlayLabel(labelWithString: "")
  private var hintMode: Bool?
  override var isFlipped: Bool { true }
  override var isOpaque: Bool { true }
  override var acceptsFirstResponder: Bool { true }
  override var wantsUpdateLayer: Bool { true }
  init(frame: CGRect, image: CGImage, display: SCDisplay, screen: NSScreen, engine: CaptureEngine) {
    self.image = image
    self.display = display
    self.screen = screen
    self.engine = engine
    super.init(frame: frame)
    wantsLayer = true
    layer?.contents = image
    crossV.style(fill: NSColor.white.withAlphaComponent(0.7))
    crossH.style(fill: NSColor.white.withAlphaComponent(0.7))
    // Dark halo under a white line keeps the outline visible on any background.
    halo.style(border: NSColor.black.withAlphaComponent(0.5), width: 2)
    outline.style(border: .white, width: 1)
    sizeLabel.font = .systemFont(ofSize: 13, weight: .semibold)
    hint.font = .systemFont(ofSize: 15, weight: .semibold)
    for label in [sizeLabel, hint] { label.textColor = .white }
    for view in [crossV, crossH, halo, outline, sizeLabel, hint] as [NSView] {
      view.wantsLayer = true
      addSubview(view)
    }
    addTrackingArea(
      NSTrackingArea(
        rect: bounds, options: [.activeAlways, .mouseMoved, .inVisibleRect], owner: self))
    setAccessibilityLabel(
      "Capture selection. Drag an area, Space for windows, Enter to capture, Escape to cancel.")
    // The first frame shows the crosshair under the pointer, not in the corner.
    let mouse = NSEvent.mouseLocation
    point = CGPoint(x: mouse.x - screen.frame.minX, y: screen.frame.maxY - mouse.y)
    refreshOverlay()
  }
  required init?(coder: NSCoder) { fatalError() }
  override func updateLayer() { layer?.contents = image }
  /// Places the crosshair, selection outline and labels (flipped, display-local points).
  func refreshOverlay() {
    if hintMode != engine.windowMode {
      hintMode = engine.windowMode
      hint.stringValue =
        engine.windowMode
        ? "Click a window · Space: area · Esc: cancel"
        : "Drag an area · Space: window · Shift: square · Enter: capture · Esc: cancel"
      hint.sizeToFit()
      hint.setFrameOrigin(CGPoint(x: 24, y: 20))
    }
    crossV.isHidden = engine.windowMode
    crossH.isHidden = engine.windowMode
    crossV.frame = CGRect(x: point.x - 0.25, y: 0, width: 0.5, height: bounds.height)
    crossH.frame = CGRect(x: 0, y: point.y - 0.25, width: bounds.width, height: 0.5)
    guard let r = selected, !r.isNull, !r.isInfinite else {
      for view in [halo, outline, sizeLabel] as [NSView] { view.isHidden = true }
      return
    }
    for view in [halo, outline, sizeLabel] as [NSView] { view.isHidden = false }
    halo.frame = r.insetBy(dx: -1, dy: -1)
    outline.frame = r.insetBy(dx: -0.5, dy: -0.5)
    sizeLabel.stringValue =
      "\(Int(r.width * screen.backingScaleFactor)) × \(Int(r.height * screen.backingScaleFactor)) px"
    sizeLabel.sizeToFit()
    sizeLabel.setFrameOrigin(CGPoint(x: max(8, r.minX), y: max(45, r.minY - 26)))
  }
  override func mouseMoved(with event: NSEvent) {
    point = convert(event.locationInWindow, from: nil)
    if engine.windowMode {
      let global = CGPoint(x: display.frame.minX + point.x, y: display.frame.minY + point.y)
      selectedWindow = engine.content?.windows.filter {
        $0.owningApplication?.processID != getpid() && $0.windowLayer == 0
          && $0.frame.contains(global) && $0.frame.width > 20 && $0.frame.height > 20
      }.min {
        (engine.windowOrder[$0.windowID] ?? Int.max) < (engine.windowOrder[$1.windowID] ?? Int.max)
      }
      selected = selectedWindow.map {
        $0.frame.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY).intersection(bounds)
      }
    }
    refreshOverlay()
  }
  override func mouseDown(with event: NSEvent) {
    mouseMoved(with: event)
    start = point
    if !engine.windowMode { selected = nil }
    refreshOverlay()
  }
  override func mouseDragged(with event: NSEvent) {
    point = convert(event.locationInWindow, from: nil)
    guard !engine.windowMode, let start else { return }
    var width = abs(point.x - start.x)
    var height = abs(point.y - start.y)
    if event.modifierFlags.contains(.shift) {
      width = max(width, height)
      height = width
    }
    if let ratio = engine.ratio { height = width / ratio }
    if let fixed = engine.fixedSize {
      width = fixed.width / screen.backingScaleFactor
      height = fixed.height / screen.backingScaleFactor
    }
    selected = CGRect(
      x: point.x >= start.x ? start.x : start.x - width,
      y: point.y >= start.y ? start.y : start.y - height, width: width, height: height
    ).intersection(bounds)
    refreshOverlay()
  }
  override func mouseUp(with event: NSEvent) {
    if selected != nil && !event.modifierFlags.contains(.command) { accept() }
  }
  func accept() {
    guard let rect = selected, rect.width >= 2, rect.height >= 2 else { return }
    let window = engine.windowMode ? selectedWindow : nil
    if window == nil {
      let sx = CGFloat(image.width) / bounds.width
      let sy = CGFloat(image.height) / bounds.height
      // A compact copy: the crop alone would keep the whole frozen display image alive. Without it
      // (out of memory) the target is captured again instead.
      engine.frozenSelection = image.cropping(
        to: CGRect(
          x: rect.minX * sx, y: rect.minY * sy, width: rect.width * sx, height: rect.height * sy
        ).integral
      ).flatMap { try? Renderer.compact($0) }
    }
    engine.finish(
      CaptureTarget(
        display: display, rect: window?.frame ?? rect, window: window,
        scale: screen.backingScaleFactor))
  }
  override func keyDown(with event: NSEvent) {
    switch event.keyCode {
    case 53: engine.finish(nil)
    case 49:
      engine.windowMode.toggle()
      selected = nil
      start = nil
      engine.refreshOverlays()
    case 36: accept()
    case 123, 124, 125, 126:
      guard var r = selected else { return }
      let amount: CGFloat =
        event.modifierFlags.contains(.shift) ? 10 : 1 / screen.backingScaleFactor
      let dx: CGFloat = event.keyCode == 123 ? -amount : event.keyCode == 124 ? amount : 0
      let dy: CGFloat = event.keyCode == 126 ? -amount : event.keyCode == 125 ? amount : 0
      if event.modifierFlags.contains(.command) {
        r.size.width = max(2, r.width + dx)
        r.size.height = max(2, r.height + dy)
      } else {
        r.origin.x += dx
        r.origin.y += dy
      }
      selected = r.intersection(bounds)
      refreshOverlay()
    default: break
    }
  }
}
