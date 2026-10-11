import AVFoundation
import AppKit
import ScreenCaptureKit
import UniformTypeIdentifiers

func require(_ result: @autoclosure () throws -> Bool, _ message: String) {
  let passed: Bool
  do { passed = try result() } catch {
    fputs("FAIL: \(message): \(error)\n", stderr)
    exit(1)
  }
  if !passed {
    fputs("FAIL: \(message)\n", stderr)
    exit(1)
  }
  print("PASS \(message)")
}
func expectFailure(_ message: String, _ work: () throws -> Void) {
  do {
    try work()
    require(false, message)
  } catch { print("PASS \(message)") }
}
func color(_ image: CGImage, _ x: Int, _ y: Int) -> NSColor {
  NSBitmapImageRep(cgImage: image).colorAt(x: x, y: y)!.usingColorSpace(.sRGB)!
}
func fixture(width: Int = 800, height: Int = 600) throws -> CGImage {
  let c = try Renderer.bitmap(size: CGSize(width: width, height: height))
  c.setFillColor(NSColor.white.cgColor)
  c.fill(CGRect(x: 0, y: 0, width: width, height: height))
  c.translateBy(x: 0, y: CGFloat(height))
  c.scaleBy(x: 1, y: -1)
  c.setFillColor(NSColor.red.cgColor)
  c.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
  c.setFillColor(NSColor.blue.cgColor)
  c.fill(CGRect(x: width - 100, y: height - 100, width: 100, height: 100))
  Renderer.text(
    "Screenshot Studio QA", at: CGPoint(x: 150, y: 160), size: 34, color: .black, context: c)
  Renderer.text(
    "contact@example.com", at: CGPoint(x: 150, y: 230), size: 28, color: .black, context: c)
  return c.makeImage()!
}

final class ScrollFixtureView: NSView {
  let image: CGImage
  override var isFlipped: Bool { true }
  init(image: CGImage) {
    self.image = image
    super.init(frame: CGRect(x: 0, y: 0, width: image.width, height: image.height))
  }
  required init?(coder: NSCoder) { fatalError() }
  override func draw(_ dirtyRect: NSRect) {
    Renderer.draw(image, in: bounds, context: NSGraphicsContext.current!.cgContext)
  }
}

/// A display placeholder for headless controller tests; nothing here talks to ScreenCaptureKit.
func placeholderDisplay() throws -> SCDisplay {
  guard let display = SCDisplay.perform(NSSelectorFromString("new"))?.takeRetainedValue() as? SCDisplay
  else { throw StudioError("Could not create a placeholder display") }
  return display
}
func pixels(_ image: CGImage) -> Data { (image.dataProvider?.data as Data?) ?? Data() }

@main struct Tests {
  @MainActor static func main() async throws {
    setbuf(stdout, nil)
    _ = NSApplication.shared
    // Keep the app lifecycle from exiting the test process when an owned test window closes.
    StudioApp.shared.operations = 1
    // STUDIO_QA_HEADLESS=1: no window is ordered on screen and nothing is captured or recorded.
    let headless = ProcessInfo.processInfo.environment["STUDIO_QA_HEADLESS"] == "1"
    let root = URL(fileURLWithPath: CommandLine.arguments[1])
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    // Sessions stay inside the QA folder, never next to the user's real recovery data.
    SessionStore.root = root.appendingPathComponent("Sessions", isDirectory: true)
    try FileManager.default.createDirectory(at: SessionStore.root, withIntermediateDirectories: true)
    let image = try fixture()
    try encode(image, to: root.appendingPathComponent("fixture.png"), type: UTType.png.identifier)
    require(
      color(image, 10, 10).redComponent > 0.9 && color(image, 790, 590).blueComponent > 0.9,
      "Fixture and renderer preserve top-left image orientation")
    let shot = try StudioDocument(image: image, base: root)
    let initial = try Renderer.image(shot.scene, store: shot.store)
    require(
      color(initial, 10, 10).redComponent > 0.9 && color(initial, 790, 590).blueComponent > 0.9,
      "Base rendering preserves pixel positions")
    try shot.change {
      $0.marks.append(Mark(tool: .redact, rect: CGRect(x: 0, y: 0, width: 110, height: 110)))
    }
    try shot.change {
      $0.marks.append(Mark(tool: .magnify, rect: CGRect(x: 0, y: 0, width: 120, height: 120)))
    }
    let redacted = try Renderer.image(shot.scene, store: shot.store)
    require(
      color(redacted, 50, 50).redComponent < 0.01 && color(redacted, 50, 50).alphaComponent > 0.99,
      "Redaction remains opaque beneath later magnification")
    try shot.undo()
    try shot.undo()
    require(shot.scene.marks.isEmpty, "Undo restores editable source without image snapshots")
    try shot.redo()
    require(shot.scene.marks.count == 1, "Redo restores redaction")
    let project = root.appendingPathComponent("sample.posshot")
    try shot.saveProject(to: project)
    let reopened = try StudioDocument(project: project)
    require(reopened.scene == shot.scene, "Editable project round trip")
    let locked = try StudioDocument(image: image, base: root)
    let before = locked.scene
    chmod(locked.directory.path, 0o500)
    expectFailure("Failed checkpoint does not commit an edit") {
      try locked.change {
        $0.marks.append(
          Mark(tool: .text, rect: CGRect(x: 0, y: 0, width: 40, height: 40), text: "unsaved"))
      }
    }
    chmod(locked.directory.path, 0o700)
    require(locked.scene == before, "Model remains unchanged after disk write failure")
    try locked.change {
      $0.marks.append(Mark(tool: .redact, rect: CGRect(x: 5, y: 5, width: 20, height: 20)))
    }
    let edited = locked.scene
    locked.saved = true
    chmod(locked.directory.path, 0o500)
    expectFailure("Undo reports failed recovery write") { try locked.undo() }
    require(locked.scene == edited && locked.saved, "Failed undo preserves scene and saved state")
    chmod(locked.directory.path, 0o700)
    try locked.undo()
    require(locked.scene == before, "Failed undo preserves history for retry")
    chmod(locked.directory.path, 0o500)
    expectFailure("Redo reports failed recovery write") { try locked.redo() }
    require(locked.scene == before, "Failed redo preserves scene")
    chmod(locked.directory.path, 0o700)
    try locked.redo()
    require(locked.scene == edited, "Failed redo preserves history for retry")
    try locked.undo()
    try locked.change {
      $0.marks.append(
        Mark(tool: .text, rect: CGRect(x: 10, y: 10, width: 50, height: 30), text: "branch"))
    }
    let branch = locked.scene
    try locked.redo()
    require(locked.scene == branch, "Editing after undo clears redo history")
    locked.discard()
    let bad = root.appendingPathComponent("bad.posshot")
    try FileManager.default.copyItem(at: project, to: bad)
    var tampered = shot.scene
    tampered.layers[0].asset = "../outside.png"
    try JSONEncoder().encode(tampered).write(to: bad.appendingPathComponent("scene.json"))
    let sessionsBefore = Set(
      (try? FileManager.default.contentsOfDirectory(atPath: SessionStore.root.path)) ?? [])
    expectFailure("Project path traversal is rejected") { _ = try StudioDocument(project: bad) }
    require(
      Set(try FileManager.default.contentsOfDirectory(atPath: SessionStore.root.path))
        == sessionsBefore,
      "Failed project import leaves no orphan recovery session")
    var invalid = shot.scene
    invalid.layers.append(invalid.layers[0])
    expectFailure("Duplicate object identifiers are rejected") {
      try StudioDocument.validate(invalid)
    }
    invalid = shot.scene
    invalid.layers[0].opacity = -1
    expectFailure("Invalid layer opacity is rejected") { try StudioDocument.validate(invalid) }
    invalid = shot.scene
    invalid.marks[0].rect.origin.x = .infinity
    expectFailure("Nonfinite annotation geometry is rejected") {
      try StudioDocument.validate(invalid)
    }
    invalid = shot.scene
    invalid.version = 999
    expectFailure("Unknown project versions are rejected") { try StudioDocument.validate(invalid) }
    let linkProject = root.appendingPathComponent("symlink.posshot")
    try FileManager.default.copyItem(at: project, to: linkProject)
    let linkAsset = linkProject.appendingPathComponent("assets").appendingPathComponent(
      shot.scene.layers[0].asset)
    try FileManager.default.removeItem(at: linkAsset)
    try FileManager.default.createSymbolicLink(
      at: linkAsset, withDestinationURL: root.appendingPathComponent("fixture.png"))
    expectFailure("Symbolic-link project assets are rejected") {
      _ = try StudioDocument(project: linkProject)
    }
    try shot.saveProject(to: project)
    let replaced = try StudioDocument(project: project)
    require(
      replaced.scene == shot.scene, "Replacing an existing project preserves a readable package")
    replaced.discard()
    expectFailure("Oversized image rejected before allocation") {
      try Limits.validate(CGSize(width: 60000, height: 60000))
    }
    expectFailure("Nonfinite dimensions rejected") {
      try Limits.validate(CGSize(width: Double.infinity, height: 4))
    }
    let cropped = try Renderer.cut(
      image, strip: CGRect(x: 0, y: 120, width: 800, height: 60), horizontal: true)
    require(
      cropped.height == 540 && color(cropped, 10, 10).redComponent > 0.9
        && color(cropped, 790, 530).blueComponent > 0.9,
      "Strip removal preserves remaining content and orientation")
    let resize = try Renderer.transformed(image, size: CGSize(width: 400, height: 300))
    require(resize.width == 400 && resize.height == 300, "Resize dimensions")
    let rotate = try Renderer.transformed(
      image, size: CGSize(width: 600, height: 800), rotation: true)
    require(rotate.width == 600 && rotate.height == 800, "Rotation dimensions")
    let orientedURL = root.appendingPathComponent("oriented.jpg")
    let orientedDest = CGImageDestinationCreateWithURL(
      orientedURL as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(
      orientedDest, image, [kCGImagePropertyOrientation: 6] as CFDictionary)
    require(CGImageDestinationFinalize(orientedDest), "EXIF fixture encodes")
    let oriented = try loadImage(orientedURL)
    require(
      oriented.width == 600 && oriented.height == 800, "EXIF rotation is applied during import")
    require(
      color(oriented, 590, 10).redComponent > 0.9 && color(oriented, 10, 790).blueComponent > 0.9,
      "EXIF rotation preserves corner content")
    let thumbnail = try loadImage(orientedURL, maxSide: 200)
    require(
      thumbnail.width == 150 && thumbnail.height == 200,
      "Downscaled import preserves EXIF orientation")
    let lines = try VisionTools.recognize(image)
    require(
      lines.contains { $0.text.contains("Screenshot Studio") }, "Real local OCR recognizes fixture")
    require(
      VisionTools.sensitive(lines).contains { $0.text.contains("example.com") },
      "Sensitive-text suggestions recognize email")
    let gif = root.appendingPathComponent("comparison.gif")
    try Renderer.gif([image, redacted], to: gif, delay: 0.5)
    let source = CGImageSourceCreateWithURL(gif as CFURL, nil)!
    require(CGImageSourceGetCount(source) == 2, "Comparison GIF contains both frames")
    let png = root.appendingPathComponent("flattened.png")
    try encode(redacted, to: png, type: UTType.png.identifier)
    let exported = try loadImage(png)
    require(color(exported, 50, 50).redComponent < 0.01, "PNG export contains flattened redaction")
    try encode(image, to: png, type: UTType.png.identifier)
    require(
      color(try loadImage(png), 50, 50).redComponent > 0.9,
      "Replacing PNG atomically publishes the new image")
    let jpeg = root.appendingPathComponent("flattened.jpg")
    try encode(redacted, to: jpeg, type: UTType.jpeg.identifier)
    require(
      color(try loadImage(jpeg), 50, 50).redComponent < 0.03,
      "JPEG export preserves opaque redaction")
    require(
      try Renderer.pixel(shot.scene, store: shot.store, at: CGPoint(x: 50, y: 50))!.redComponent
        < 0.01,
      "Pixel sampler cannot reveal redacted source")
    for effect in [Tool.blur, .pixelate, .magnify, .spotlight] {
      var privacy = shot.scene
      privacy.marks.append(Mark(tool: effect, rect: CGRect(x: 0, y: 0, width: 180, height: 180)))
      let rendered = try Renderer.image(privacy, store: shot.store, maxSide: 400)
      require(
        color(rendered, 25, 25).redComponent < 0.01
          && color(rendered, 25, 25).alphaComponent > 0.99,
        "Downscaled redaction survives \(effect.rawValue)")
    }
    let same = try Stitcher.match(image, image)
    require(same.advance == 0, "Scrolling detects unchanged frames")
    // Deterministic, non-repeating content with exact known overlap.
    let c = try Renderer.bitmap(size: CGSize(width: 800, height: 1600))
    c.setFillColor(NSColor.white.cgColor)
    c.fill(CGRect(x: 0, y: 0, width: 800, height: 1600))
    var seed: UInt64 = 777
    for y in stride(from: 0, to: 1600, by: 8) {
      for x in stride(from: 0, to: 800, by: 16) {
        seed = seed &* 6_364_136_223_846_793_005 &+ 1
        let v = CGFloat((seed >> 32) % 256) / 255
        c.setFillColor(NSColor(white: v, alpha: 1).cgColor)
        c.fill(CGRect(x: x, y: y, width: 16, height: 8))
      }
    }
    let tall = c.makeImage()!
    let a = tall.cropping(to: CGRect(x: 0, y: 0, width: 800, height: 800))!
    let b = tall.cropping(to: CGRect(x: 0, y: 320, width: 800, height: 800))!
    let alignment = try Stitcher.match(a, b)
    require(alignment.advance == 320, "Scrolling recovers pixel-exact vertical overlap")
    for advance in [81, 157, 239, 401, 479] {
      let frame = tall.cropping(to: CGRect(x: 0, y: advance, width: 800, height: 800))!
      let match = try Stitcher.match(a, frame)
      require(match.advance == advance, "Scrolling recovers non-grid advance \(advance)")
    }
    expectFailure("Changed viewport dimensions stop scrolling") { _ = try Stitcher.match(a, image) }
    let unrelated = tall.cropping(to: CGRect(x: 0, y: 800, width: 800, height: 800))!
    expectFailure("Unrelated scrolling frames fail closed") { _ = try Stitcher.match(a, unrelated) }
    let wide = try Renderer.transformed(
      tall, size: CGSize(width: 1600, height: 800), rotation: true)
    let left = wide.cropping(to: CGRect(x: 0, y: 0, width: 800, height: 800))!
    let right = wide.cropping(to: CGRect(x: 320, y: 0, width: 800, height: 800))!
    let horizontal = try Stitcher.match(left, right, horizontal: true)
    require(horizontal.advance == 320, "Scrolling recovers pixel-exact horizontal overlap")
    try encode(
      tall, to: root.appendingPathComponent("scroll-fixture.png"), type: UTType.png.identifier)
    // Render every tool, catching malformed drawing paths and effect regressions.
    for tool in Tool.allCases where tool != .select {
      var scene = shot.scene
      scene.marks = [
        Mark(
          tool: tool, rect: CGRect(x: 100, y: 100, width: 160, height: 100),
          end: CGPoint(x: 260, y: 200), points: [CGPoint(x: 100, y: 100), CGPoint(x: 260, y: 200)],
          text: "1")
      ]
      _ = try Renderer.image(scene, store: shot.store, maxSide: 400)
    }
    print("PASS all annotation tools render")
    // New assets are kept in memory; their recovery PNG is written in the background.
    let storeRoot = root.appendingPathComponent("store-check")
    let store = try ImageStore(root: storeRoot)
    let asset = try store.add(image)
    require(try store.image(asset) === image, "New assets are served from memory, not re-decoded")
    try store.flush()
    require(
      FileManager.default.fileExists(atPath: storeRoot.appendingPathComponent(asset).path),
      "Asset PNG is written in the background and flushed on demand")
    require(try store.image(asset) === image, "Written assets stay in the decoded-image cache")
    store.purge()
    let decoded = try store.image(asset)
    require(
      decoded !== image && decoded.width == image.width && decoded.height == image.height
        && color(decoded, 10, 10).redComponent > 0.9,
      "Purged assets decode from their written PNG")
    store.purge()
    let crop = image.cropping(to: CGRect(x: 40, y: 40, width: 120, height: 90))!
    let compacted = try Renderer.compact(crop)
    require(
      compacted.width == 120 && compacted.height == 90
        && color(compacted, 10, 10).redComponent > 0.9
        && color(compacted, 110, 80).greenComponent > 0.9,
      "Compacted crops keep their pixels and orientation")
    // Blur, pixelate and magnifier pieces are cached per document revision.
    var effectScene = shot.scene
    effectScene.marks = [
      Mark(tool: .blur, rect: CGRect(x: 120, y: 120, width: 200, height: 120)),
      Mark(tool: .pixelate, rect: CGRect(x: 400, y: 200, width: 160, height: 160)),
      Mark(tool: .magnify, rect: CGRect(x: 600, y: 400, width: 150, height: 150)),
    ]
    func paint(_ cache: EffectCache?) throws -> Data {
      let c = try Renderer.bitmap(size: effectScene.size)
      c.translateBy(x: 0, y: effectScene.size.height)
      c.scaleBy(x: 1, y: -1)
      for mark in effectScene.marks {
        try Renderer.draw(mark, context: c, scene: effectScene, store: shot.store, effects: cache)
      }
      return c.makeImage().map(pixels) ?? Data()
    }
    let effects = EffectCache()
    effects.validate(1)
    let uncached = try paint(nil)
    let firstPaint = try paint(effects)
    let reused = try paint(effects)
    require(
      effects.images.count == 3 && !uncached.isEmpty && firstPaint == uncached && reused == uncached,
      "Cached blur, pixelate and magnifier pieces render identically")
    effects.validate(2)
    require(effects.images.isEmpty, "A new document revision drops cached effect pieces")
    let effectDocument = try StudioDocument(image: image, base: root)
    try effectDocument.change {
      $0.marks.append(Mark(tool: .blur, rect: CGRect(x: 120, y: 120, width: 200, height: 120)))
    }
    let effectCanvas = Canvas(effectDocument)
    effectCanvas.setZoom(1)
    func drawCanvas() {
      if let rep = effectCanvas.bitmapImageRepForCachingDisplay(in: effectCanvas.bounds) {
        effectCanvas.cacheDisplay(in: effectCanvas.bounds, to: rep)
      }
    }
    drawCanvas()
    let cachedPiece = effectCanvas.effects.images.values.first
    drawCanvas()
    require(
      effectCanvas.effects.revision == effectDocument.revision
        && effectCanvas.effects.images.count == 1 && cachedPiece != nil
        && effectCanvas.effects.images.values.first === cachedPiece,
      "Canvas redraws reuse the effect piece of the current revision")
    try effectDocument.change {
      $0.marks.append(Mark(tool: .pixelate, rect: CGRect(x: 400, y: 200, width: 160, height: 160)))
    }
    drawCanvas()
    require(
      effectCanvas.effects.revision == effectDocument.revision
        && effectCanvas.effects.images.count == 2,
      "An edit re-renders effect pieces for the new revision")
    effectDocument.discard()
    // Undo bounds use each state's cached encoded size.
    let history = try StudioDocument(image: image, base: root)
    for i in 0..<110 {
      try history.change {
        $0.marks.append(
          Mark(tool: .rectangle, rect: CGRect(x: i * 5, y: i * 5, width: 20, height: 20)))
      }
    }
    var undone = 0
    while undone < 200 {
      let before = history.revision
      try history.undo()
      if history.revision == before { break }
      undone += 1
    }
    require(
      undone == 100 && history.scene.marks.count == 10, "Undo keeps the newest 100 edit states")
    history.discard()
    try autoreleasepool {
      let large = try fixture(width: 3840, height: 2160)
      let benchmark = try StudioDocument(image: large, base: root)
      try benchmark.change { scene in
        for i in 0..<100 {
          scene.marks.append(
            Mark(
              tool: .arrow,
              rect: CGRect(x: (i % 10) * 320, y: (i / 10) * 180, width: 100, height: 80),
              end: CGPoint(x: (i % 10) * 320 + 100, y: (i / 10) * 180 + 80)))
        }
      }
      var timings: [Double] = []
      for _ in 0..<5 {
        let start = ProcessInfo.processInfo.systemUptime
        _ = try Renderer.image(benchmark.scene, store: benchmark.store, maxSide: 4096)
        timings.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
      }
      var usage = rusage_info_v2()
      let result = withUnsafeMutablePointer(to: &usage) {
        $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
          proc_pid_rusage(getpid(), RUSAGE_INFO_V2, $0)
        }
      }
      let report: [String: Any] = [
        "fixture": "4K image with 100 annotations", "render_ms": timings,
        "footprint_bytes": result == 0 ? usage.ri_phys_footprint : 0,
        "rss_bytes": result == 0 ? usage.ri_resident_size : 0,
      ]
      try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        .write(to: root.appendingPathComponent("performance.json"))
      require(
        timings.dropFirst().max()! < 250, "4K / 100-annotation warm render stays below 250 ms")
      print(
        "Measured footprint: \(usage.ri_phys_footprint/1_048_576) MiB; RSS: \(usage.ri_resident_size/1_048_576) MiB"
      )
      benchmark.discard()
    }
    // Repeated sessions exercise cache release and disk cleanup without large parallel allocations.
    func footprint() -> UInt64 {
      var usage = rusage_info_v2()
      let result = withUnsafeMutablePointer(to: &usage) {
        $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
          proc_pid_rusage(getpid(), RUSAGE_INFO_V2, $0)
        }
      }
      return result == 0 ? usage.ri_phys_footprint : 0
    }
    shot.store.purge()
    let baseline = footprint()
    var peak = baseline
    for index in 0..<40 {
      try autoreleasepool {
        let session = try StudioDocument(image: image, base: root)
        let path = session.directory
        try session.change {
          $0.marks.append(Mark(tool: .redact, rect: CGRect(x: 0, y: 0, width: 100, height: 100)))
        }
        _ = try Renderer.image(session.scene, store: session.store)
        try session.undo()
        try session.redo()
        peak = max(peak, footprint())
        session.discard()
        if FileManager.default.fileExists(atPath: path.path) {
          throw StudioError("Stress session \(index) left temporary data")
        }
      }
    }
    let growth = peak > baseline ? peak - baseline : 0
    require(
      baseline > 0 && growth < 96 * 1_048_576,
      "40 capture/edit/render/discard cycles stay within 96 MiB footprint growth")
    print("Lifecycle stress footprint growth: \(growth / 1_048_576) MiB")
    reopened.discard()
    shot.discard()
    // A closed editor must not keep its window, canvas, preview or document alive.
    weak var closedEditor: EditorController?
    weak var closedWindow: NSWindow?
    weak var closedCanvas: Canvas?
    weak var closedDocument: StudioDocument?
    var closedDirectory: URL?
    try autoreleasepool {
      let document = try StudioDocument(image: image, base: root)
      document.saved = true
      let editor = EditorController(document)
      editor.canvas.refresh()  // runs the canvas → editor change callback
      closedEditor = editor
      closedWindow = editor.window
      closedCanvas = editor.canvas
      closedDocument = document
      closedDirectory = document.directory
      editor.window?.close()
    }
    try await Task.sleep(nanoseconds: 800_000_000)
    require(
      closedEditor == nil && closedWindow == nil && closedCanvas == nil && closedDocument == nil,
      "A closed editor releases its window, canvas and document")
    require(
      closedDirectory.map { !FileManager.default.fileExists(atPath: $0.path) } == true,
      "Closing the last view of a capture removes its temporary session")
    // Esc in Quick Actions goes through the close button's save check (saved here, so no prompt).
    let quickShot = try StudioDocument(image: image, base: root)
    quickShot.saved = true
    let quick = try PreviewController(quickShot)
    (quick.window as? QuickActionsWindow)?.cancelOperation(nil)
    require(
      !FileManager.default.fileExists(atPath: quickShot.directory.path),
      "Esc closes Quick Actions through the same path as the close button")
    // A recording whose stream stops by itself frees the window, captures and logout.
    let placeholder = CaptureTarget(
      display: try placeholderDisplay(), rect: CGRect(x: 0, y: 0, width: 320, height: 200),
      window: nil, scale: 1)
    let neverStarted = try RecordingController(target: placeholder)
    neverStarted.settleDelay = 0.05
    neverStarted.busy = true
    neverStarted.stopping = true
    neverStarted.ended(StudioError("The display was disconnected"))
    require(
      neverStarted.stream == nil && !neverStarted.stopping && neverStarted.busy,
      "A stream that stops with an error is released at once while the file settles")
    try await Task.sleep(nanoseconds: 300_000_000)
    require(
      !neverStarted.busy && !neverStarted.finished && neverStarted.startButton.isEnabled
        && !neverStarted.stopButton.isEnabled
        && neverStarted.windowShouldClose(neverStarted.window!),
      "After a stream error with nothing recorded, Record is available and the window closes")
    let neverStartedDirectory = neverStarted.file.deletingLastPathComponent()
    neverStarted.window?.close()
    require(
      !FileManager.default.fileExists(atPath: neverStartedDirectory.path),
      "Closing the reset recorder removes its temporary files")
    let partial = try RecordingController(target: placeholder)
    partial.settleDelay = 0.05
    partial.busy = true
    partial.started = Date()
    try Data(repeating: 1, count: 4096).write(to: partial.file)
    partial.ended(StudioError("The window was closed"))
    try await Task.sleep(nanoseconds: 300_000_000)
    require(
      partial.finished && !partial.busy && partial.stream == nil
        && FileManager.default.fileExists(atPath: partial.file.path),
      "A stream that stops by itself keeps the recorded part for trimming or saving")
    partial.saved = true
    require(partial.windowShouldClose(partial.window!), "A settled recording window can close")
    partial.window?.close()
    let broken = try RecordingController(target: placeholder)
    broken.started = Date()
    try Data(repeating: 1, count: 4096).write(to: broken.file)
    broken.ended(StudioError("The disk is full"), outputFailed: true)
    try await Task.sleep(nanoseconds: 200_000_000)
    require(
      !broken.finished && !broken.busy && !broken.failed && broken.startButton.isEnabled
        && !FileManager.default.fileExists(atPath: broken.file.path),
      "A failed recording output is discarded and Record is available again")
    broken.window?.close()
    // ⌘⇧2 preparation that never answers is abandoned once, without a modal report.
    let engine = CaptureEngine()
    engine.preparationTimeout = 0.2
    var notices: [String] = []
    var reports: [String] = []
    var lateCurrent: Bool?
    engine.notice = { notices.append($0) }
    engine.report = { reports.append($0.localizedDescription) }
    engine.prepare = { engine, token in
      try await Task.sleep(nanoseconds: 600_000_000)  // a wedged ScreenCaptureKit call
      lateCurrent = engine.isCurrent(token)
      throw StudioError("late failure")
    }
    let preparationStart = ProcessInfo.processInfo.systemUptime
    let timedOut = try await engine.choose(mode: "area")
    let waited = ProcessInfo.processInfo.systemUptime - preparationStart
    require(
      timedOut == nil && engine.selection == nil && notices.count == 1 && reports.isEmpty
        && waited < 1,
      "A hung capture preparation ends the selection after its timeout with one notice")
    try await Task.sleep(nanoseconds: 700_000_000)
    require(
      lateCurrent == false && notices.count == 1 && reports.isEmpty,
      "A preparation that answers after the timeout is dropped, not reported again")
    engine.prepare = { _, _ in }
    let empty = try await engine.choose(mode: "window")
    require(
      empty == nil && engine.selection == nil && reports.count == 1 && notices.count == 1,
      "A preparation that shows no selector ends the selection with one report")
    try await Task.sleep(nanoseconds: 300_000_000)
    require(notices.count == 1, "A finished selection's timeout never fires a notice")
    engine.preparationTimeout = 5
    engine.prepare = { _, _ in try await Task.sleep(nanoseconds: 10_000_000_000) }
    let pending = Task { await engine.select(windowMode: false) }
    try await Task.sleep(nanoseconds: 100_000_000)
    let concurrent = await engine.select(windowMode: false)
    require(
      engine.selection != nil && concurrent == nil,
      "A second selection while one is preparing is refused instead of replacing it")
    engine.finish(nil)
    let cancelled = await pending.value
    require(cancelled == nil && engine.selection == nil, "Cancelling resumes the waiting capture")
    let deadlineStart = ProcessInfo.processInfo.systemUptime
    var gaveUp = false
    do {
      _ = try await withDeadline(0.1) {
        try await Task.sleep(nanoseconds: 3_000_000_000)
        return 1
      }
    } catch { gaveUp = error is StudioError }
    let answered = try await withDeadline(1) { 42 }
    require(
      gaveUp && answered == 42 && ProcessInfo.processInfo.systemUptime - deadlineStart < 1,
      "ScreenCaptureKit calls give up after their deadline and pass timely answers through")
    // The selector composites the frozen image once; pointer moves only move small overlay views.
    if let screen = NSScreen.main ?? NSScreen.screens.first {
      let selector = CaptureEngine()
      let frozen = try fixture(width: 640, height: 400)
      let view = SelectionView(
        frame: CGRect(origin: .zero, size: screen.frame.size), image: frozen,
        display: try placeholderDisplay(), screen: screen, engine: selector)
      let host = NSWindow(
        contentRect: CGRect(origin: .zero, size: screen.frame.size), styleMask: .borderless,
        backing: .buffered, defer: false)
      host.isReleasedWhenClosed = false
      host.contentView = view
      host.displayIfNeeded()
      view.point = CGPoint(x: 200, y: 150)
      view.selected = CGRect(x: 100, y: 120, width: 300, height: 200)
      view.refreshOverlay()
      let scale = screen.backingScaleFactor
      require(
        (view.layer?.contents as AnyObject?) === frozen && view.wantsUpdateLayer,
        "The selector shows its frozen image as layer contents, never redrawn per move")
      require(
        view.outline.layer?.borderWidth == 1 && view.halo.layer?.borderWidth == 2
          && view.crossV.layer?.backgroundColor != nil,
        "Overlay strokes are styled before their first display pass")
      require(
        view.outline.frame == CGRect(x: 99.5, y: 119.5, width: 301, height: 201)
          && view.halo.frame == CGRect(x: 99, y: 119, width: 302, height: 202)
          && !view.outline.isHidden && !view.crossV.isHidden && view.crossV.frame.midX == 200
          && view.crossH.frame.midY == 150
          && view.sizeLabel.stringValue == "\(Int(300 * scale)) × \(Int(200 * scale)) px",
        "Selection outline, crosshair and size label follow the selection")
      if let superview = view.superview {
        let edge = view.convert(CGPoint(x: 100, y: 120), to: superview)
        let label = view.convert(
          CGPoint(x: view.sizeLabel.frame.midX, y: view.sizeLabel.frame.midY), to: superview)
        require(
          view.hitTest(edge) === view && view.hitTest(label) === view,
          "Overlay pieces never intercept the pointer")
      }
      selector.windowMode = true
      view.selected = .null
      view.refreshOverlay()
      require(
        view.crossV.isHidden && view.outline.isHidden && view.sizeLabel.isHidden
          && view.hint.stringValue.hasPrefix("Click a window"),
        "Window mode hides the crosshair and switches the hint")
      host.close()
    }
    // quit-if-idle: idle means nothing open or in flight; the URL never opens UI.
    let app = StudioApp.shared
    app.operations = 0
    let emptyIsIdle = app.isIdle
    app.controllers.append(NSWindowController())
    let windowIsIdle = app.isIdle
    app.controllers.removeAll()
    app.operations = 1
    require(
      emptyIsIdle && !windowIsIdle && !app.isIdle,
      "quit-if-idle treats only an empty helper as idle")
    app.application(NSApp, open: [URL(string: "pos-screenshot://quit-if-idle?force=1")!])
    require(!app.quitWhenLaunched, "Malformed quit-if-idle URLs are ignored")
    app.application(NSApp, open: [URL(string: "pos-screenshot://quit-if-idle")!])
    require(
      app.receivedCommand && app.quitWhenLaunched && app.controllers.isEmpty && app.chooser == nil
        && app.capture.selection == nil,
      "quit-if-idle opens no UI and is decided once launch finishes")
    app.quitWhenLaunched = false
    // Exercise real window layout offscreen and export a view snapshot without screen permissions.
    let uiShot = try StudioDocument(image: image, base: root)
    let editor = EditorController(uiShot)
    editor.selectTool(.arrow)
    require(editor.canvas.tool == .arrow && editor.toolButtons[.arrow]?.state == .on && editor.toolButtons[.select]?.state == .off,
      "Toolbar selection stays synchronized with the active drawing tool")
    editor.selectTool(.select)
    if !headless { editor.window?.orderFront(nil) }
    editor.fit()
    try await Task.sleep(nanoseconds: 300_000_000)
    editor.window?.contentView?.layoutSubtreeIfNeeded()
    if let view = editor.window?.contentView,
      let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)
    {
      view.cacheDisplay(in: view.bounds, to: rep)
      if let data = rep.representation(using: .png, properties: [:]) {
        try data.write(to: root.appendingPathComponent("editor-ui.png"))
      }
    }
    require(editor.commands.count >= 35, "Editor exposes advanced command palette")
    require(
      !editor.window!.contentView!.hasAmbiguousLayout, "Editor layout has determinate geometry")
    if headless {
      print("SKIP live capture/recording: STUDIO_QA_HEADLESS=1")
    } else if CGPreflightScreenCaptureAccess() {
      let fixtureWindow = NSWindow(
        contentRect: CGRect(x: 100, y: 100, width: 640, height: 480), styleMask: [.titled],
        backing: .buffered, defer: false)
      fixtureWindow.title = "Screenshot Studio Owned QA Fixture"
      fixtureWindow.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
      fixtureWindow.isReleasedWhenClosed = false
      let imageView = NSImageView(frame: fixtureWindow.contentView!.bounds)
      imageView.image = NSImage(cgImage: image, size: .zero)
      imageView.imageScaling = .scaleProportionallyUpOrDown
      imageView.autoresizingMask = [.width, .height]
      fixtureWindow.contentView = imageView
      fixtureWindow.orderFront(nil)
      try await Task.sleep(nanoseconds: 500_000_000)
      let content = try await SCShareableContent.excludingDesktopWindows(
        false, onScreenWindowsOnly: true)
      guard
        let window = content.windows.first(where: {
          $0.windowID == CGWindowID(fixtureWindow.windowNumber)
        }), let display = content.displays.first
      else { throw StudioError("Owned capture fixture window was not enumerated") }
      let target = CaptureTarget(display: display, rect: window.frame, window: window, scale: 1)
      let engine = CaptureEngine()
      let capture = try await engine.capture(target)
      require(
        capture.width > 100 && capture.height > 100, "Real ScreenCaptureKit window capture succeeds"
      )
      try encode(
        capture, to: root.appendingPathComponent("live-window-capture.png"),
        type: UTType.png.identifier)
      let scrolling = NSScrollView(frame: fixtureWindow.contentView!.bounds)
      scrolling.hasVerticalScroller = true
      scrolling.documentView = ScrollFixtureView(image: tall)
      fixtureWindow.contentView = scrolling
      scrolling.contentView.scroll(to: .zero)
      scrolling.reflectScrolledClipView(scrolling.contentView)
      try await Task.sleep(nanoseconds: 300_000_000)
      let scrollBefore = try await engine.capture(target)
      scrolling.contentView.scroll(to: CGPoint(x: 0, y: 200))
      scrolling.reflectScrolledClipView(scrolling.contentView)
      try await Task.sleep(nanoseconds: 300_000_000)
      let scrollAfter = try await engine.capture(target)
      try encode(
        scrollBefore, to: root.appendingPathComponent("scroll-before.png"),
        type: UTType.png.identifier)
      try encode(
        scrollAfter, to: root.appendingPathComponent("scroll-after.png"),
        type: UTType.png.identifier)
      let realMatch = try Stitcher.match(scrollBefore, scrollAfter)
      require(
        abs(realMatch.advance - 200) <= 1,
        "Live scrolling window aligns at the exact scroll distance")
      fixtureWindow.contentView = imageView
      let cancelledRecorder = try RecordingController(target: target)
      let cancelledDirectory = cancelledRecorder.file.deletingLastPathComponent()
      cancelledRecorder.start()
      try await Task.sleep(nanoseconds: 2_500_000_000)
      cancelledRecorder.cancel()
      try await Task.sleep(nanoseconds: 1_000_000_000)
      require(
        cancelledRecorder.started == nil && cancelledRecorder.stream == nil
          && !cancelledRecorder.busy,
        "Cancel during the final countdown second never starts recording")
      require(
        !FileManager.default.fileExists(atPath: cancelledDirectory.path),
        "Countdown cancellation cleans temporary recording files")
      let recorder = try RecordingController(target: target)
      recorder.start()
      let deadline = Date().addingTimeInterval(20)
      while recorder.started == nil && Date() < deadline {
        try await Task.sleep(nanoseconds: 100_000_000)
      }
      require(recorder.started != nil, "Real recording starts after countdown")
      try await Task.sleep(nanoseconds: 1_500_000_000)
      recorder.stop()
      while !recorder.finished && Date() < deadline {
        try await Task.sleep(nanoseconds: 100_000_000)
      }
      require(recorder.finished, "Real recording finalizes after Stop")
      let asset = AVURLAsset(url: recorder.file)
      let duration = try await asset.load(.duration)
      require(duration.seconds >= 1 && duration.seconds < 6, "Recorded MP4 has expected duration")
      try copyFile(recorder.file, to: root.appendingPathComponent("recording-fixture.mp4"))
      recorder.saved = true
      recorder.window?.close()
      fixtureWindow.close()
    } else {
      print("SKIP live capture/recording: Screen Recording permission unavailable to test process")
    }
    uiShot.saved = true
    editor.window?.close()
    uiShot.discard()
    try Data("complete".utf8).write(to: root.appendingPathComponent("qa-complete"))
    print("Screenshot Studio native QA passed")
  }
}
