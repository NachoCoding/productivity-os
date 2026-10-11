import AppKit
import CoreImage
import ImageIO
import UniformTypeIdentifiers

/// Rendered blur/pixelate/magnifier pieces of one document revision, so redraws reuse them.
final class EffectCache {
  var revision = -1
  var images: [UUID: CGImage] = [:]
  func validate(_ revision: Int) {
    guard revision != self.revision else { return }
    images.removeAll()
    self.revision = revision
  }
}

enum Renderer {
  static func pixel(_ scene: Scene, store: ImageStore, at point: CGPoint) throws -> NSColor? {
    guard CGRect(origin: .zero, size: scene.size).contains(point) else { return nil }
    let c = try bitmap(size: CGSize(width: 1, height: 1))
    c.translateBy(x: 0, y: 1)
    c.scaleBy(x: 1, y: -1)
    c.translateBy(x: -floor(point.x), y: -floor(point.y))
    for layer in scene.layers {
      c.saveGState()
      c.setAlpha(layer.opacity)
      draw(try store.image(layer.asset), in: layer.rect, context: c)
      c.restoreGState()
    }
    for mark in scene.marks where mark.tool != .redact {
      try draw(mark, context: c, scene: scene, store: store)
    }
    for mark in scene.marks where mark.tool == .redact {
      c.setFillColor(NSColor.black.cgColor)
      c.fill(mark.rect.integral)
    }
    return c.makeImage().flatMap { NSBitmapImageRep(cgImage: $0).colorAt(x: 0, y: 0) }
  }
  static let ci = CIContext(options: [.cacheIntermediates: false])
  static func bitmap(size: CGSize) throws -> CGContext {
    try Limits.validate(size)
    guard
      let ctx = CGContext(
        data: nil, width: Int(ceil(size.width)), height: Int(ceil(size.height)),
        bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { throw StudioError("Not enough memory to render this image") }
    return ctx
  }
  /// A standalone copy of `image`. A crop shares (and keeps alive) its parent's pixels, e.g. a whole
  /// frozen display or scroll frame, so crops are compacted before they are stored.
  static func compact(_ image: CGImage) throws -> CGImage {
    let c = try bitmap(size: CGSize(width: image.width, height: image.height))
    c.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    guard let copy = c.makeImage() else { throw StudioError("Not enough memory to copy this image") }
    return copy
  }
  /// All outgoing images use this renderer. Top-left pixel coordinates throughout.
  static func image(
    _ scene: Scene, store: ImageStore, maxSide: CGFloat? = nil, decorate: Bool = true
  ) throws -> CGImage {
    let pad = decorate && scene.backdrop.enabled ? scene.backdrop.padding : 0
    let full = CGSize(width: scene.size.width + pad * 2, height: scene.size.height + pad * 2)
    let scale = maxSide.map { min(1, $0 / max(full.width, full.height)) } ?? 1
    let ctx = try bitmap(
      size: CGSize(width: ceil(full.width * scale), height: ceil(full.height * scale)))
    ctx.translateBy(x: 0, y: CGFloat(ctx.height))
    ctx.scaleBy(x: scale, y: -scale)
    if pad > 0 {
      let colors =
        [scene.backdrop.first.color.cgColor, scene.backdrop.second.color.cgColor] as CFArray
      if let gradient = CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 1])
      {
        ctx.drawLinearGradient(
          gradient, start: .zero, end: CGPoint(x: full.width, y: full.height),
          options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
      }
    }
    ctx.translateBy(x: pad, y: pad)
    let rect = CGRect(origin: .zero, size: scene.size)
    if pad > 0 {
      let path = CGPath(
        roundedRect: rect, cornerWidth: scene.backdrop.radius, cornerHeight: scene.backdrop.radius,
        transform: nil)
      if scene.backdrop.shadow {
        ctx.saveGState()
        ctx.setShadow(
          offset: CGSize(width: 0, height: -8), blur: 25,
          color: NSColor.black.withAlphaComponent(0.35).cgColor)
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.addPath(path)
        ctx.fillPath()
        ctx.restoreGState()
      }
      ctx.addPath(path)
      ctx.clip()
    } else {
      ctx.clip(to: rect)
    }
    for layer in scene.layers {
      ctx.saveGState()
      ctx.setAlpha(layer.opacity)
      draw(try store.image(layer.asset), in: layer.rect, context: ctx)
      ctx.restoreGState()
    }
    // Privacy marks are ALWAYS last: later overlays, blur, or magnifiers cannot reveal covered pixels.
    for mark in scene.marks where mark.tool != .redact {
      try draw(mark, context: ctx, scene: scene, store: store)
    }
    for mark in scene.marks where mark.tool == .redact {
      ctx.setFillColor(NSColor.black.cgColor)
      ctx.fill(mark.rect.integral)
    }
    guard let result = ctx.makeImage() else { throw StudioError("Could not finish rendering") }
    return result
  }
  static func draw(_ image: CGImage, in rect: CGRect, context: CGContext) {
    context.saveGState()
    context.translateBy(x: rect.minX, y: rect.maxY)
    context.scaleBy(x: 1, y: -1)
    context.draw(image, in: CGRect(origin: .zero, size: rect.size))
    context.restoreGState()
  }
  /// `effects` caches effect pieces by mark id; pass it only for marks of `scene` whose revision it tracks.
  static func draw(
    _ m: Mark, context c: CGContext, scene: Scene, store: ImageStore, effects: EffectCache? = nil
  ) throws {
    c.saveGState()
    defer { c.restoreGState() }
    c.setStrokeColor(m.ink.color.cgColor)
    c.setFillColor(m.ink.color.cgColor)
    c.setLineWidth(m.width)
    c.setLineCap(.round)
    c.setLineJoin(.round)
    let r = m.rect.standardized
    switch m.tool {
    case .rectangle: c.stroke(r)
    case .ellipse: c.strokeEllipse(in: r)
    case .redact:
      c.setFillColor(NSColor.black.cgColor)
      c.fill(r.integral)
    case .erase: c.fill(r)
    case .highlight:
      c.setAlpha(0.32)
      c.fill(r)
    case .spotlight:
      c.setFillColor(NSColor.black.withAlphaComponent(0.6).cgColor)
      c.addRect(CGRect(origin: .zero, size: scene.size))
      c.addRect(r)
      c.fillPath(using: .evenOdd)
    case .arrow, .curvedArrow, .ruler:
      let start = m.points.first ?? r.origin
      let end = m.end ?? CGPoint(x: r.maxX, y: r.maxY)
      var tangent = start
      c.move(to: start)
      if m.tool == .curvedArrow {
        let control = CGPoint(
          x: (start.x + end.x) / 2 + (end.y - start.y) * 0.3,
          y: (start.y + end.y) / 2 - (end.x - start.x) * 0.3)
        c.addQuadCurve(to: end, control: control)
        tangent = control
      } else {
        c.addLine(to: end)
      }
      c.strokePath()
      if m.tool == .ruler {
        let length = hypot(end.x - start.x, end.y - start.y)
        text(
          String(format: "%.0f px · %.1f pt", length, length / scene.scale),
          at: CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2), size: m.fontSize,
          color: m.ink.color, context: c)
      } else {
        let angle = atan2(end.y - tangent.y, end.x - tangent.x)
        let length = max(15, m.width * 4)
        c.move(
          to: CGPoint(x: end.x - length * cos(angle - 0.5), y: end.y - length * sin(angle - 0.5)))
        c.addLine(to: end)
        c.addLine(
          to: CGPoint(x: end.x - length * cos(angle + 0.5), y: end.y - length * sin(angle + 0.5)))
        c.strokePath()
      }
    case .pen:
      if let first = m.points.first {
        c.move(to: first)
        for p in m.points.dropFirst() { c.addLine(to: p) }
        c.strokePath()
      }
    case .text: text(m.text, at: r.origin, size: m.fontSize, color: m.ink.color, context: c)
    case .callout:
      c.addPath(CGPath(roundedRect: r, cornerWidth: 10, cornerHeight: 10, transform: nil))
      c.fillPath()
      c.move(to: CGPoint(x: r.minX + 18, y: r.maxY - 1))
      c.addLine(to: CGPoint(x: r.minX + 18, y: r.maxY + 16))
      c.addLine(to: CGPoint(x: r.minX + 40, y: r.maxY - 1))
      c.closePath()
      c.fillPath()
      text(
        m.text, at: CGPoint(x: r.minX + 10, y: r.minY + 8), size: m.fontSize, color: .white,
        context: c)
    case .step:
      c.fillEllipse(in: r)
      text(
        m.text, at: CGPoint(x: r.midX - m.fontSize * 0.3, y: r.midY - m.fontSize * 0.6),
        size: m.fontSize, color: .white, context: c)
    case .blur, .pixelate, .magnify:
      let crop = r.intersection(CGRect(origin: .zero, size: scene.size)).integral
      guard crop.width > 0, crop.height > 0 else { return }
      let piece: CGImage
      if let cached = effects?.images[m.id] {
        piece = cached
      } else {
        guard let rendered = try effect(m, crop: crop, scene: scene, store: store) else { return }
        piece = rendered
        effects?.images[m.id] = rendered
      }
      if m.tool == .magnify {
        c.addEllipse(in: crop)
        c.clip()
      }
      draw(piece, in: crop, context: c)
    case .select: break
    }
  }
  /// The image an effect mark shows over `crop`; nil when Core Image produces nothing.
  static func effect(_ m: Mark, crop: CGRect, scene: Scene, store: ImageStore) throws -> CGImage? {
    // Render only base layers, with redactions already flattened before sampling any effect.
    let local = try bitmap(size: crop.size)
    local.translateBy(x: 0, y: crop.height)
    local.scaleBy(x: 1, y: -1)
    local.translateBy(x: -crop.minX, y: -crop.minY)
    for layer in scene.layers where layer.rect.intersects(crop) {
      local.saveGState()
      local.setAlpha(layer.opacity)
      draw(try store.image(layer.asset), in: layer.rect, context: local)
      local.restoreGState()
    }
    for redaction in scene.marks
    where redaction.tool == .redact && redaction.rect.intersects(crop) {
      local.setFillColor(NSColor.black.cgColor)
      local.fill(redaction.rect.integral)
    }
    guard let piece = local.makeImage() else { throw StudioError("Effect could not be rendered") }
    if m.tool == .magnify {
      let center = CGRect(
        x: CGFloat(piece.width) * 0.25, y: CGFloat(piece.height) * 0.25,
        width: CGFloat(piece.width) * 0.5, height: CGFloat(piece.height) * 0.5)
      return piece.cropping(to: center) ?? piece
    }
    let input = CIImage(cgImage: piece)
    let output =
      m.tool == .blur
      ? input.clampedToExtent().applyingFilter(
        "CIGaussianBlur", parameters: [kCIInputRadiusKey: max(8, m.width * 3)]
      ).cropped(to: input.extent)
      : input.applyingFilter(
        "CIPixellate", parameters: [kCIInputScaleKey: max(12, m.width * 4)])
    return ci.createCGImage(output, from: input.extent)
  }
  static func text(
    _ text: String, at point: CGPoint, size: CGFloat, color: NSColor, context: CGContext
  ) {
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
    (text as NSString).draw(
      at: point,
      withAttributes: [
        .font: NSFont.systemFont(ofSize: size, weight: .semibold), .foregroundColor: color,
      ])
    NSGraphicsContext.restoreGraphicsState()
  }
  static func transformed(
    _ image: CGImage, size: CGSize, rotation: Bool = false, flip: Bool = false
  ) throws -> CGImage {
    let ctx = try bitmap(size: size)
    if rotation {
      ctx.translateBy(x: size.width, y: 0)
      ctx.rotate(by: .pi / 2)
      ctx.draw(image, in: CGRect(x: 0, y: 0, width: size.height, height: size.width))
    } else {
      if flip {
        ctx.translateBy(x: size.width, y: 0)
        ctx.scaleBy(x: -1, y: 1)
      }
      ctx.draw(image, in: CGRect(origin: .zero, size: size))
    }
    guard let result = ctx.makeImage() else { throw StudioError("Could not finish rendering") }
    return result
  }
  static func cut(_ image: CGImage, strip: CGRect, horizontal: Bool) throws -> CGImage {
    let size = CGSize(width: image.width, height: image.height)
    let start = floor(horizontal ? strip.minY : strip.minX)
    let end = ceil(horizontal ? strip.maxY : strip.maxX)
    let extent = horizontal ? size.height : size.width
    guard start >= 0, end <= extent, end > start, end - start < extent else {
      throw StudioError("Select an interior strip to remove")
    }
    let result = CGSize(
      width: size.width - (horizontal ? 0 : end - start),
      height: size.height - (horizontal ? end - start : 0))
    let c = try bitmap(size: result)
    c.translateBy(x: 0, y: result.height)
    c.scaleBy(x: 1, y: -1)
    let a =
      horizontal
      ? CGRect(x: 0, y: 0, width: size.width, height: start)
      : CGRect(x: 0, y: 0, width: start, height: size.height)
    let b =
      horizontal
      ? CGRect(x: 0, y: end, width: size.width, height: extent - end)
      : CGRect(x: end, y: 0, width: extent - end, height: size.height)
    if let part = image.cropping(to: a), start > 0 { draw(part, in: a, context: c) }
    if let part = image.cropping(to: b), end < extent {
      var target = b
      if horizontal { target.origin.y = start } else { target.origin.x = start }
      draw(part, in: target, context: c)
    }
    guard let result = c.makeImage() else { throw StudioError("Could not finish rendering") }
    return result
  }
  static func gif(_ frames: [CGImage], to url: URL, delay: Double) throws {
    guard !frames.isEmpty,
      let dest = CGImageDestinationCreateWithURL(
        url as CFURL, UTType.gif.identifier as CFString, frames.count, nil)
    else { throw StudioError("Cannot create GIF") }
    CGImageDestinationSetProperties(
      dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
    for frame in frames {
      CGImageDestinationAddImage(
        dest, frame,
        [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay]] as CFDictionary)
    }
    guard CGImageDestinationFinalize(dest) else { throw StudioError("Could not finish GIF") }
  }
}
