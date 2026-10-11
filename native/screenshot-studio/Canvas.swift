import AppKit

@MainActor final class Canvas: NSView {
  let shot: StudioDocument
  var tool: Tool = .select
  var ink = Ink(), stroke: CGFloat = 4, fontSize: CGFloat = 28
  var zoom: CGFloat = 1
  var preview: CGImage?
  var selection: CGRect?
  var selected = Set<UUID>()
  var selectedLayer: UUID?
  var draft: Mark?
  var start: CGPoint?
  var panStart: CGPoint?
  var moving = false
  var movingDelta = CGPoint.zero
  var dragBackground: CGImage?
  var guides: [CGFloat] = []
  var changed: (() -> Void)?
  var status: ((String) -> Void)?
  var onDrop: ((URL) -> Void)?
  /// Blur, pixelate and magnifier pieces are rendered once per document revision, not on every redraw.
  let effects = EffectCache()
  override var isFlipped: Bool { true }
  override var acceptsFirstResponder: Bool { true }
  init(_ shot: StudioDocument) {
    self.shot = shot
    super.init(frame: CGRect(origin: .zero, size: shot.scene.size))
    registerForDraggedTypes([.fileURL])
    setAccessibilityLabel(
      "Screenshot canvas. Drag to select or annotate. Enter crops selection. Delete removes selected annotations."
    )
    addTrackingArea(
      NSTrackingArea(
        rect: .zero, options: [.activeInKeyWindow, .mouseMoved, .inVisibleRect], owner: self))
  }
  required init?(coder: NSCoder) { fatalError() }
  func refresh() {
    do {
      preview = try Renderer.image(shot.scene, store: shot.store, maxSide: 4096, decorate: false)
    } catch { StudioApp.shared.report(error) }
    frame.size = CGSize(width: shot.scene.size.width * zoom, height: shot.scene.size.height * zoom)
    needsDisplay = true
    changed?()
  }
  func setZoom(_ value: CGFloat) {
    zoom = min(8, max(0.03, value))
    refresh()
  }
  override func draw(_ dirtyRect: NSRect) {
    guard let c = NSGraphicsContext.current?.cgContext else { return }
    NSColor.windowBackgroundColor.setFill()
    bounds.fill()
    c.saveGState()
    c.scaleBy(x: zoom, y: zoom)
    effects.validate(shot.revision)
    if zoom >= 1, dragBackground == nil {
      c.interpolationQuality = .none
      for layer in shot.scene.layers {
        if let image = try? shot.store.image(layer.asset) {
          c.saveGState()
          c.setAlpha(layer.opacity)
          Renderer.draw(image, in: layer.rect, context: c)
          c.restoreGState()
        }
      }
      for mark in shot.scene.marks where mark.tool != .redact {
        try? Renderer.draw(mark, context: c, scene: shot.scene, store: shot.store, effects: effects)
      }
      for mark in shot.scene.marks where mark.tool == .redact {
        try? Renderer.draw(mark, context: c, scene: shot.scene, store: shot.store)
      }
    } else if let preview = dragBackground ?? preview {
      Renderer.draw(preview, in: CGRect(origin: .zero, size: shot.scene.size), context: c)
    }
    if dragBackground != nil {
      c.saveGState()
      c.translateBy(x: movingDelta.x, y: movingDelta.y)
      for mark in shot.scene.marks where selected.contains(mark.id) {
        try? Renderer.draw(mark, context: c, scene: shot.scene, store: shot.store, effects: effects)
      }
      if let layer = shot.scene.layers.first(where: { $0.id == selectedLayer }),
        let image = try? shot.store.image(layer.asset)
      {
        c.setAlpha(layer.opacity)
        Renderer.draw(image, in: layer.rect, context: c)
      }
      c.restoreGState()
    }
    if let draft { try? Renderer.draw(draft, context: c, scene: shot.scene, store: shot.store) }
    c.setLineWidth(1 / zoom)
    c.setStrokeColor(NSColor.controlAccentColor.cgColor)
    c.setLineDash(phase: 0, lengths: [5 / zoom, 3 / zoom])
    if let selection { c.stroke(selection) }
    for mark in shot.scene.marks where selected.contains(mark.id) {
      c.stroke(
        mark.rect.offsetBy(dx: movingDelta.x, dy: movingDelta.y).insetBy(
          dx: -4 / zoom, dy: -4 / zoom))
    }
    if let layer = shot.scene.layers.first(where: { $0.id == selectedLayer }) {
      c.stroke(layer.rect.offsetBy(dx: movingDelta.x, dy: movingDelta.y))
    }
    if guides.count == 2 {
      c.setStrokeColor(NSColor.systemTeal.cgColor)
      c.move(to: CGPoint(x: guides[0], y: 0))
      c.addLine(to: CGPoint(x: guides[0], y: shot.scene.size.height))
      c.move(to: CGPoint(x: 0, y: guides[1]))
      c.addLine(to: CGPoint(x: shot.scene.size.width, y: guides[1]))
      c.strokePath()
    }
    c.restoreGState()
  }
  func position(_ event: NSEvent) -> CGPoint {
    let p = convert(event.locationInWindow, from: nil)
    return CGPoint(x: p.x / zoom, y: p.y / zoom)
  }
  override func mouseDown(with event: NSEvent) {
    window?.makeFirstResponder(self)
    let p = position(event)
    start = p
    if event.modifierFlags.contains(.option) {
      panStart = event.locationInWindow
      return
    }
    if tool == .select {
      if let mark = shot.scene.marks.reversed().first(where: {
        $0.rect.insetBy(dx: -8 / zoom, dy: -8 / zoom).contains(p)
      }) {
        if !event.modifierFlags.contains(.shift) && !selected.contains(mark.id) {
          selected.removeAll()
        }
        selected.insert(mark.id)
        selectedLayer = nil
        if let group = mark.group {
          selected.formUnion(shot.scene.marks.filter { $0.group == group }.map(\.id))
        }
        moving = true
        selection = nil
      } else {
        selected.removeAll()
        if let layer = shot.scene.layers.dropFirst().reversed().first(where: { $0.rect.contains(p) }
        ), !event.modifierFlags.contains(.control) {
          selectedLayer = layer.id
          moving = true
          selection = nil
        } else {
          selectedLayer = nil
          selection = CGRect(origin: p, size: .zero)
          moving = false
        }
      }
      if moving {
        movingDelta = .zero
        var scene = shot.scene
        scene.marks.removeAll { selected.contains($0.id) }
        scene.layers.removeAll { $0.id == selectedLayer }
        dragBackground = try? Renderer.image(
          scene, store: shot.store, maxSide: 4096, decorate: false)
      }
    } else if tool == .text || tool == .callout {
      if let value = input(
        "Add text", message: "Text remains editable. Double-click a text object to change it.")
      {
        edit {
          $0.marks.append(
            Mark(
              tool: tool,
              rect: CGRect(
                x: p.x, y: p.y, width: max(40, CGFloat(value.count) * fontSize * 0.65) + 20,
                height: fontSize * 1.5 + 16), text: value, ink: ink, fontSize: fontSize))
        }
      }
    } else {
      var mark = Mark(
        tool: tool, rect: CGRect(origin: p, size: .zero), points: [p], ink: ink, width: stroke,
        fontSize: fontSize)
      if tool == .step {
        mark.text = String(shot.scene.marks.filter { $0.tool == .step }.count + 1)
        mark.rect = CGRect(x: p.x - 22, y: p.y - 22, width: 44, height: 44)
      }
      if tool == .erase { mark.ink = Ink(pixel(at: p) ?? .white) }
      draft = mark
    }
    if event.clickCount == 2, let id = selected.first,
      let mark = shot.scene.marks.first(where: { $0.id == id }),
      mark.tool == .text || mark.tool == .callout,
      let text = input("Edit text", message: "Update the selected text", value: mark.text)
    {
      edit { scene in
        if let i = scene.marks.firstIndex(where: { $0.id == id }) { scene.marks[i].text = text }
      }
    }
    needsDisplay = true
  }
  override func mouseDragged(with event: NSEvent) {
    if let panStart, let scroll = enclosingScrollView {
      let delta = CGPoint(
        x: event.locationInWindow.x - panStart.x, y: event.locationInWindow.y - panStart.y)
      var origin = scroll.contentView.bounds.origin
      origin.x -= delta.x
      origin.y += delta.y
      scroll.contentView.scroll(to: origin)
      scroll.reflectScrolledClipView(scroll.contentView)
      self.panStart = event.locationInWindow
      return
    }
    guard let start else { return }
    let p = position(event)
    let r = CGRect(
      x: min(start.x, p.x), y: min(start.y, p.y), width: abs(p.x - start.x),
      height: abs(p.y - start.y))
    if tool == .select {
      if !moving {
        selection = r
      } else {
        movingDelta = CGPoint(x: p.x - start.x, y: p.y - start.y)
        guides = []
        if let source = shot.scene.marks.first(where: { selected.contains($0.id) })?.rect
          ?? shot.scene.layers.first(where: { $0.id == selectedLayer })?.rect
        {
          let targets =
            shot.scene.marks.filter { !selected.contains($0.id) }.map(\.rect)
            + shot.scene.layers.filter { $0.id != selectedLayer }.map(\.rect)
          let xs = targets.flatMap { [$0.minX, $0.midX, $0.maxX] }
          let ys = targets.flatMap { [$0.minY, $0.midY, $0.maxY] }
          let x = source.minX + movingDelta.x
          let y = source.minY + movingDelta.y
          let snapX = xs.min(by: { abs($0 - x) < abs($1 - x) })
          let snapY = ys.min(by: { abs($0 - y) < abs($1 - y) })
          if !event.modifierFlags.contains(.control) {
            if let snapX, abs(snapX - x) < 6 / zoom { movingDelta.x = snapX - source.minX }
            if let snapY, abs(snapY - y) < 6 / zoom { movingDelta.y = snapY - source.minY }
            guides = [source.minX + movingDelta.x, source.minY + movingDelta.y]
          }
        }
      }
    } else if draft != nil {
      if tool != .step { draft?.rect = r }
      draft?.end = p
      if tool == .pen, (draft?.points.count ?? 0) < 100_000 { draft?.points.append(p) }
    }
    needsDisplay = true
  }
  override func mouseUp(with event: NSEvent) {
    defer {
      start = nil
      draft = nil
      panStart = nil
      moving = false
      movingDelta = .zero
      dragBackground = nil
      guides = []
      needsDisplay = true
    }
    if panStart != nil { return }
    if tool == .select, moving, let start {
      let p = position(event)
      let dx = dragBackground != nil ? movingDelta.x : p.x - start.x
      let dy = dragBackground != nil ? movingDelta.y : p.y - start.y
      edit { scene in
        if let i = scene.layers.firstIndex(where: { $0.id == selectedLayer }) {
          scene.layers[i].rect = scene.layers[i].rect.offsetBy(dx: dx, dy: dy)
        }
        for i in scene.marks.indices where selected.contains(scene.marks[i].id) {
          scene.marks[i].rect.origin.x += dx
          scene.marks[i].rect.origin.y += dy
          scene.marks[i].points = scene.marks[i].points.map { CGPoint(x: $0.x + dx, y: $0.y + dy) }
          if let e = scene.marks[i].end { scene.marks[i].end = CGPoint(x: e.x + dx, y: e.y + dy) }
        }
      }
    } else if let draft, draft.rect.width > 1 || draft.rect.height > 1 {
      edit { $0.marks.append(draft) }
    }
  }
  override func mouseMoved(with event: NSEvent) {
    let p = position(event)
    if let color = pixel(at: p)?.usingColorSpace(.sRGB) {
      status?(
        String(
          format: "%.0f, %.0f px · #%02X%02X%02X · %.0f%%", p.x, p.y, Int(color.redComponent * 255),
          Int(color.greenComponent * 255), Int(color.blueComponent * 255), zoom * 100))
    }
  }
  func pixel(at p: CGPoint, exact: Bool = false) -> NSColor? {
    if exact { return try? Renderer.pixel(shot.scene, store: shot.store, at: p) }
    guard let preview else { return nil }
    let x = Int(p.x * CGFloat(preview.width) / shot.scene.size.width)
    let y = Int(p.y * CGFloat(preview.height) / shot.scene.size.height)
    guard x >= 0, y >= 0, x < preview.width, y < preview.height,
      let one = preview.cropping(to: CGRect(x: x, y: y, width: 1, height: 1))
    else { return nil }
    let rep = NSBitmapImageRep(cgImage: one)
    return rep.colorAt(x: 0, y: 0)
  }
  func edit(_ body: (inout Scene) throws -> Void) {
    do {
      try shot.change(body)
      refresh()
    } catch { StudioApp.shared.report(error) }
  }
  func flatten(_ image: CGImage) {
    do {
      let asset = try shot.store.add(image)
      edit {
        $0.size = CGSize(width: image.width, height: image.height)
        $0.layers = [Layer(asset: asset, rect: CGRect(origin: .zero, size: $0.size))]
        $0.marks = []
      }
      selection = nil
      selected = []
    } catch { StudioApp.shared.report(error) }
  }
  func crop() {
    guard let selection else { return }
    do {
      let image = try Renderer.image(shot.scene, store: shot.store, decorate: false)
      if let crop = try image.cropping(
        to: selection.intersection(CGRect(origin: .zero, size: shot.scene.size)).integral
      ).map(Renderer.compact) {
        flatten(crop)
      }
    } catch { StudioApp.shared.report(error) }
  }
  override func keyDown(with event: NSEvent) {
    let command = event.modifierFlags.contains(.command)
    let shift = event.modifierFlags.contains(.shift)
    let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
    if command && key == "c" {
      copy(nil)
      return
    }
    if command && key == "s" {
      do { _ = try StudioApp.shared.save(shot) } catch { StudioApp.shared.report(error) }
      return
    }
    if command && key == "z" {
      do {
        if shift { try shot.redo() } else { try shot.undo() }
        refresh()
      } catch { StudioApp.shared.report(error) }
      return
    }
    if command && key == "d" {
      edit { scene in
        let copies = scene.marks.filter { selected.contains($0.id) }.map { m -> Mark in
          var n = m
          n.id = UUID()
          n.group = nil
          n.rect = n.rect.offsetBy(dx: 12, dy: 12)
          n.points = n.points.map { CGPoint(x: $0.x + 12, y: $0.y + 12) }
          if let e = n.end { n.end = CGPoint(x: e.x + 12, y: e.y + 12) }
          return n
        }
        scene.marks += copies
      }
      return
    }
    if command && key == "a" {
      selected = Set(shot.scene.marks.map(\.id))
      needsDisplay = true
      return
    }
    if command && (key == "+" || key == "=") {
      setZoom(zoom * 1.25)
      return
    }
    if command && key == "-" {
      setZoom(zoom / 1.25)
      return
    }
    if event.keyCode == 36 {
      crop()
      return
    }
    if event.keyCode == 51 {
      edit {
        $0.marks.removeAll { selected.contains($0.id) }
        $0.layers.removeAll { $0.id == selectedLayer }
      }
      selected = []
      selectedLayer = nil
      return
    }
    if event.keyCode == 53 {
      selection = nil
      selected = []
      needsDisplay = true
      return
    }
    if [123, 124, 125, 126].contains(event.keyCode) {
      let n: CGFloat = shift ? 10 : 1
      let dx: CGFloat = event.keyCode == 123 ? -n : event.keyCode == 124 ? n : 0
      let dy: CGFloat = event.keyCode == 126 ? -n : event.keyCode == 125 ? n : 0
      edit { scene in
        if let i = scene.layers.firstIndex(where: { $0.id == selectedLayer }) {
          if command {
            let ratio = scene.layers[i].rect.height / max(1, scene.layers[i].rect.width)
            scene.layers[i].rect.size.width = max(1, scene.layers[i].rect.width + dx + dy)
            scene.layers[i].rect.size.height = scene.layers[i].rect.width * ratio
          } else {
            scene.layers[i].rect = scene.layers[i].rect.offsetBy(dx: dx, dy: dy)
          }
        }
        for i in scene.marks.indices where selected.contains(scene.marks[i].id) {
          if command {
            var rect = scene.marks[i].rect
            rect.size.width = max(1, rect.width + dx)
            rect.size.height = max(1, rect.height + dy)
            scene.marks[i].resize(to: rect)
          } else {
            scene.marks[i].rect = scene.marks[i].rect.offsetBy(dx: dx, dy: dy)
            scene.marks[i].points = scene.marks[i].points.map {
              CGPoint(x: $0.x + dx, y: $0.y + dy)
            }
            if let e = scene.marks[i].end { scene.marks[i].end = CGPoint(x: e.x + dx, y: e.y + dy) }
          }
        }
      }
      return
    }
    let shortcuts: [String: Tool] = [
      "v": .select, "a": .arrow, "t": .text, "r": .rectangle, "h": .highlight, "x": .redact,
      "p": .pen,
    ]
    if let tool = shortcuts[key] {
      self.tool = tool
      status?(tool.rawValue)
      return
    }
    super.keyDown(with: event)
  }
  override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }
  @objc func copy(_ sender: Any?) {
    do { try StudioApp.shared.copy(shot) } catch { StudioApp.shared.report(error) }
  }
  @objc func paste(_ sender: Any?) {
    guard let editor = window?.windowController as? EditorController else { return }
    editor.pasteImage()
  }
  override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
    guard
      let urls = sender.draggingPasteboard.readObjects(
        forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
      let url = urls.first
    else { return false }
    onDrop?(url)
    return true
  }
}
