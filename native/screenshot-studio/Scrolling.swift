import AppKit
import ApplicationServices

struct StitchResult {
  let advance: Int
  let error: Double
  var stickyTail: Int = 0
}
enum Stitcher {
  static func gray(_ image: CGImage, horizontal: Bool, detailed: Bool = false) throws -> (
    pixels: [UInt8], width: Int, height: Int
  ) {
    let w = horizontal ? image.height : image.width
    let h = horizontal ? image.width : image.height
    let width = 96
    let height = detailed ? h : min(1000, max(1, Int(Double(h) * 96 / Double(w))))
    var bytes = [UInt8](repeating: 0, count: width * height)
    try bytes.withUnsafeMutableBytes { p in
      guard
        let c = CGContext(
          data: p.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
          space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
      else { throw StudioError("Not enough memory to compare scrolling frames") }
      if horizontal {
        c.translateBy(x: 0, y: CGFloat(height))
        c.rotate(by: -.pi / 2)
        c.draw(image, in: CGRect(x: 0, y: 0, width: height, height: width))
      } else {
        c.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
      }
    }
    // CoreGraphics raw bitmap rows are top-to-bottom for an untransformed image draw.
    return (bytes, width, height)
  }
  static func match(_ previous: CGImage, _ next: CGImage, horizontal: Bool = false) throws
    -> StitchResult
  {
    guard previous.width == next.width, previous.height == next.height else {
      throw StudioError("Viewport changed size. Capture stopped with the verified portion.")
    }
    let a = try gray(previous, horizontal: horizontal)
    let b = try gray(next, horizontal: horizontal)
    let h = a.height
    let w = a.width
    let identical =
      zip(a.pixels, b.pixels).reduce(0.0) { $0 + Double(abs(Int($1.0) - Int($1.1))) }
      / Double(a.pixels.count)
    if identical < 0.5 { return StitchResult(advance: 0, error: identical) }
    guard h >= 24 else { throw StudioError("Viewport is too short to align reliably") }
    // Ignore edges: fixed headers/scrollbars do not contribute to alignment confidence.
    let margin = max(2, h / 10)
    let minimum = max(2, h / 25)
    let maximum = h * 3 / 4
    var scores: [(Int, Double)] = []
    for shift in minimum...maximum {
      var sum = 0.0
      var count = 0
      for y in stride(from: margin, to: h - shift - margin, by: 2) {
        for x in stride(from: 8, to: w - 8, by: 3) {
          sum += Double(abs(Int(a.pixels[(y + shift) * w + x]) - Int(b.pixels[y * w + x])))
          count += 1
        }
      }
      if count > 100 { scores.append((shift, sum / Double(count))) }
    }
    guard let best = scores.min(by: { $0.1 < $1.1 }), best.1 < 48 else {
      throw StudioError("Could not align the next frame. Try a smaller scroll or manual mode.")
    }
    let full = horizontal ? previous.width : previous.height
    let da = try gray(previous, horizontal: horizontal, detailed: true)
    let db = try gray(next, horizontal: horizontal, detailed: true)
    let radius = max(3, Int(ceil(Double(full) / Double(h))) * 2)
    let marginFull = max(2, full / 10)
    var refined: (Int, Double)?
    var candidates = Set<Int>()
    var refinedScores: [(Int, Double)] = []
    for candidate in scores.sorted(by: { $0.1 < $1.1 }).prefix(8) {
      let approximate = Int((Double(candidate.0) * Double(full) / Double(h)).rounded())
      for shift in max(1, approximate - radius)...min(full - 1, approximate + radius) {
        candidates.insert(shift)
      }
    }
    for shift in candidates {
      var error = 0.0
      var count = 0
      for y in stride(from: marginFull, to: full - shift - marginFull, by: 3) {
        for x in stride(from: 8, to: 88, by: 4) {
          error += Double(abs(Int(da.pixels[(y + shift) * 96 + x]) - Int(db.pixels[y * 96 + x])))
          count += 1
        }
      }
      if count > 0 {
        let value = error / Double(count)
        refinedScores.append((shift, value))
        if refined == nil || value < refined!.1 { refined = (shift, value) }
      }
    }
    guard let refined, refined.1 < 12 else {
      throw StudioError("Pixel alignment is uncertain. Try a smaller scroll.")
    }
    let competing =
      refinedScores.filter { abs($0.0 - refined.0) > max(8, full / 30) }.map(\.1).min() ?? 255
    guard competing > refined.1 + 1.5 else {
      throw StudioError(
        "Repeated content makes alignment uncertain. The verified portion is preserved.")
    }
    // Detect a stationary trailing footer/sidebar. Require visible detail to avoid treating blank
    // margins as fixed UI. Keep the footer only at the end of the stitched result.
    var tail = 0
    var detail = 0.0
    for y in stride(from: full - 1, through: full - full / 5, by: -1) {
      var error = 0.0
      var rowMin = 255
      var rowMax = 0
      for x in stride(from: 8, to: 88, by: 4) {
        let v = Int(da.pixels[y * 96 + x])
        error += Double(abs(v - Int(db.pixels[y * 96 + x])))
        rowMin = min(rowMin, v)
        rowMax = max(rowMax, v)
      }
      if error / 20 > 0.8 { break }
      tail += 1
      detail = max(detail, Double(rowMax - rowMin))
    }
    if detail < 12 { tail = 0 }
    return StitchResult(advance: refined.0, error: refined.1, stickyTail: tail)
  }
}

@MainActor final class ScrollController: NSWindowController, NSWindowDelegate {
  let target: CaptureTarget
  let horizontal: Bool
  let manual: Bool
  let shot: StudioDocument
  var previous: CGImage
  var stopped = false, busy = false, frames = 1
  var footerLayer: UUID?
  var discardRequested = false
  let message = label("Scroll capture ready"), preview = NSImageView()
  init(target: CaptureTarget, image: CGImage, horizontal: Bool, manual: Bool) throws {
    self.target = target
    self.horizontal = horizontal
    self.manual = manual
    previous = image
    shot = try StudioDocument(image: image, scale: target.scale)
    let window = NSPanel(
      contentRect: CGRect(x: 0, y: 0, width: 390, height: 340),
      styleMask: [.titled, .closable, .utilityWindow], backing: .buffered, defer: false)
    window.title = "Scrolling Capture"
    window.level = .floating
    window.isReleasedWhenClosed = false
    super.init(window: window)
    window.delegate = self
    preview.imageScaling = .scaleProportionallyUpOrDown
    preview.image = NSImage(cgImage: image, size: .zero)
    preview.heightAnchor.constraint(equalToConstant: 220).isActive = true
    let buttons = row([
      ClickButton(manual ? "Add Frame" : "Start") { [weak self] in self?.start() },
      ClickButton("Finish") { [weak self] in self?.finish() },
      ClickButton("Cancel") { [weak self] in self?.cancel() },
    ])
    fill(column([preview, message, buttons]), in: window.contentView!)
    window.center()
  }
  required init?(coder: NSCoder) { fatalError() }
  func start() {
    guard !busy, !stopped else { return }
    busy = true
    Task {
      defer {
        busy = false
        if stopped {
          if discardRequested {
            shot.discard()
            window?.close()
          } else {
            finish()
          }
        }
      }
      repeat {
        do {
          if !manual {
            guard AXIsProcessTrusted() else {
              throw StudioError(
                "Automatic scrolling needs Accessibility permission. Use manual scrolling or enable Screenshot Studio in System Settings → Privacy & Security → Accessibility."
              )
            }
            let global = CGPoint(
              x: target.display.frame.minX + target.rect.midX,
              y: target.display.frame.minY + target.rect.midY)
            let event = CGEvent(
              scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
              wheel1: horizontal ? 0 : -Int32(target.rect.height * 0.4),
              wheel2: horizontal ? -Int32(target.rect.width * 0.4) : 0, wheel3: 0)
            event?.location = global
            event?.post(tap: .cghidEventTap)
            try await Task.sleep(nanoseconds: 650_000_000)
          }
          guard !stopped else { break }
          let next = try await StudioApp.shared.capture.capture(target)
          let old = previous
          let direction = horizontal
          let match = try await ImageWorker.shared.run {
            try Stitcher.match(old, next, horizontal: direction)
          }
          if match.advance == 0 {
            message.stringValue = "End reached or no movement. \(frames) frames captured."
            break
          }
          let extent = horizontal ? next.width : next.height
          guard match.advance > 0, match.advance < extent else {
            throw StudioError("Invalid overlap; capture stopped")
          }
          let tail = match.stickyTail
          let crop =
            horizontal
            ? CGRect(
              x: next.width - match.advance - tail, y: 0, width: match.advance, height: next.height)
            : CGRect(
              x: 0, y: next.height - match.advance - tail, width: next.width, height: match.advance)
          guard let strip = try next.cropping(to: crop).map(Renderer.compact) else {
            throw StudioError("Could not extract aligned strip")
          }
          var size = shot.scene.size
          if horizontal {
            size.width += CGFloat(match.advance)
          } else {
            size.height += CGFloat(match.advance)
          }
          try Limits.validate(size)
          let asset = try shot.store.add(strip)
          let previousTail =
            footerLayer.flatMap { id in shot.scene.layers.first { $0.id == id } }.map {
              horizontal ? $0.rect.width : $0.rect.height
            } ?? (frames == 1 ? CGFloat(tail) : 0)
          let origin =
            horizontal
            ? CGPoint(x: shot.scene.size.width - previousTail, y: 0)
            : CGPoint(x: 0, y: shot.scene.size.height - previousTail)
          var footer: Layer?
          if tail > 0 {
            let r =
              horizontal
              ? CGRect(x: next.width - tail, y: 0, width: tail, height: next.height)
              : CGRect(x: 0, y: next.height - tail, width: next.width, height: tail)
            if let image = try next.cropping(to: r).map(Renderer.compact) {
              let name = try shot.store.add(image)
              footer = Layer(
                asset: name,
                rect: CGRect(
                  x: origin.x + (horizontal ? CGFloat(match.advance) : 0),
                  y: origin.y + (horizontal ? 0 : CGFloat(match.advance)),
                  width: CGFloat(image.width), height: CGFloat(image.height)))
            }
          }
          try shot.change {
            if let footerLayer { $0.layers.removeAll { $0.id == footerLayer } }
            if frames == 1, tail > 0, let first = $0.layers.first {
              let base = try shot.store.image(first.asset)
              let r =
                horizontal
                ? CGRect(x: 0, y: 0, width: base.width - tail, height: base.height)
                : CGRect(x: 0, y: 0, width: base.width, height: base.height - tail)
              if let trimmed = try base.cropping(to: r).map(Renderer.compact) {
                $0.layers[0].asset = try shot.store.add(trimmed)
                $0.layers[0].rect = r
              }
            }
            $0.layers.append(
              Layer(
                asset: asset,
                rect: CGRect(origin: origin, size: CGSize(width: strip.width, height: strip.height))
              ))
            if let footer { $0.layers.append(footer) }
            $0.size = CGSize(
              width: size.width - (horizontal ? previousTail - CGFloat(tail) : 0),
              height: size.height - (horizontal ? 0 : previousTail - CGFloat(tail)))
          }
          footerLayer = footer?.id
          previous = next
          frames += 1
          message.stringValue = "\(frames) frames · \(Int(size.width)) × \(Int(size.height)) px"
          let scene = shot.scene
          let store = shot.store
          let thumb = try await ImageWorker.shared.run {
            try Renderer.image(scene, store: store, maxSide: 700)
          }
          preview.image = NSImage(cgImage: thumb, size: .zero)
          if frames >= 100 {
            message.stringValue = "Frame limit reached. Finish to use this capture."
            break
          }
        } catch {
          message.stringValue = error.localizedDescription
          break
        }
      } while !manual && !stopped
    }
  }
  func finish() {
    stopped = true
    guard !busy else {
      message.stringValue = "Finishing…"
      return
    }
    StudioApp.shared.edit(shot)
    window?.close()
  }
  func cancel() {
    discardRequested = true
    guard !busy else {
      stopped = true
      message.stringValue = "Cancelling…"
      return
    }
    stopped = true
    shot.discard()
    window?.close()
  }
  func windowShouldClose(_ sender: NSWindow) -> Bool {
    if busy {
      stopped = true
      return false
    }
    return StudioApp.shared.mayClose(shot)
  }
  func windowWillClose(_ notification: Notification) {
    stopped = true
    StudioApp.shared.release(self, shot: shot)
  }
}
