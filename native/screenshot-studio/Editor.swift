import AppKit
import CoreImage
import UniformTypeIdentifiers

@MainActor final class EditorController: NSWindowController, NSWindowDelegate, NSSearchFieldDelegate
{
  let shot: StudioDocument, canvas: Canvas
  let status = label(""), search = NSSearchField(), more = NSPopUpButton()
  var commands: [(String, () -> Void)] = []
  var toolButtons: [Tool: NSButton] = [:]
  var busy = false
  init(_ shot: StudioDocument) {
    self.shot = shot
    canvas = Canvas(shot)
    let window = NSWindow(
      contentRect: CGRect(x: 0, y: 0, width: 1120, height: 780),
      styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false
    )
    window.title = "Screenshot Studio"
    window.minSize = CGSize(width: 1000, height: 480)
    window.isReleasedWhenClosed = false
    super.init(window: window)
    window.delegate = self
    let tools: [Tool] = [.select, .arrow, .text, .rectangle, .highlight, .redact]
    let toolbar = row(
      tools.map { t in
        let button = ClickButton(t.rawValue) { [weak self] in self?.selectTool(t) }
        button.setButtonType(.pushOnPushOff)
        button.state = canvas.tool == t ? .on : .off
        toolButtons[t] = button
        return button
      })
    let color = NSColorWell()
    color.color = .systemRed
    color.target = self
    color.action = #selector(colorChanged(_:))
    color.setAccessibilityLabel("Annotation color")
    color.widthAnchor.constraint(equalToConstant: 42).isActive = true
    let width = NSSlider(
      value: 4, minValue: 1, maxValue: 24, target: self, action: #selector(widthChanged(_:)))
    width.widthAnchor.constraint(equalToConstant: 85).isActive = true
    width.setAccessibilityLabel("Stroke width")
    let options = row([
      color, label("Stroke"), width,
      ClickButton("−") { [weak self] in
        guard let self else { return }
        canvas.setZoom(canvas.zoom / 1.25)
      }, ClickButton("Fit") { [weak self] in self?.fit() },
      ClickButton("+") { [weak self] in
        guard let self else { return }
        canvas.setZoom(canvas.zoom * 1.25)
      },
      ClickButton("Undo") { [weak self] in
        self?.perform {
          try self?.shot.undo()
          self?.canvas.refresh()
        }
      },
      ClickButton("Redo") { [weak self] in
        self?.perform {
          try self?.shot.redo()
          self?.canvas.refresh()
        }
      },
    ])
    let output = row([
      ClickButton("Copy", symbol: "doc.on.doc") { [weak self] in
        self?.perform { try StudioApp.shared.copy(shot) }
      },
      ClickButton("Save", symbol: "square.and.arrow.down") { [weak self] in
        self?.perform { _ = try StudioApp.shared.save(shot) }
      },
      ClickButton("Share", symbol: "square.and.arrow.up") { [weak self] in self?.share() },
      ClickButton("Pin", symbol: "pin") { [weak self] in
        self?.perform { try StudioApp.shared.pin(shot) }
      },
      ClickButton("Add Capture") { [weak self] in self?.addCapture() },
    ])
    more.target = self
    more.action = #selector(runMore(_:))
    more.setAccessibilityLabel("More editing tools")
    search.placeholderString = "Find a tool…"
    search.setAccessibilityLabel("Find an editing tool")
    search.delegate = self
    search.widthAnchor.constraint(equalToConstant: 180).isActive = true
    let scroll = NSScrollView()
    scroll.hasVerticalScroller = true
    scroll.hasHorizontalScroller = true
    scroll.documentView = canvas
    scroll.drawsBackground = true
    scroll.backgroundColor = .underPageBackgroundColor
    let stack = column(
      [row([toolbar, more, search]), row([options, output]), scroll, status], spacing: 10)
    scroll.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 280).isActive = true
    fill(stack, in: window.contentView!)
    // The canvas lives inside the window: its callbacks reach the window and document only through
    // a weak controller, or a closed editor (window, canvas, preview, undo history) is never freed.
    canvas.status = { [weak self] in self?.status.stringValue = $0 }
    canvas.changed = { [weak self] in
      guard let self else { return }
      self.window?.isDocumentEdited = !self.shot.saved
      status.stringValue =
        "\(Int(self.shot.scene.size.width)) × \(Int(self.shot.scene.size.height)) px · \(Int(canvas.zoom*100))% · Option-drag to pan"
    }
    canvas.onDrop = { [weak self] in self?.addImage($0) }
    configureCommands()
    filterCommands("")
    window.center()
    DispatchQueue.main.async { [weak self] in
      self?.fit()
      self?.window?.makeFirstResponder(self?.canvas)
    }
  }
  required init?(coder: NSCoder) { fatalError() }
  @objc func colorChanged(_ sender: NSColorWell) {
    canvas.ink = Ink(sender.color)
    if !canvas.selected.isEmpty {
      canvas.edit { scene in
        for i in scene.marks.indices where canvas.selected.contains(scene.marks[i].id) {
          scene.marks[i].ink = canvas.ink
        }
      }
    }
  }
  @objc func widthChanged(_ sender: NSSlider) {
    canvas.stroke = sender.doubleValue
    if !canvas.selected.isEmpty {
      canvas.edit { scene in
        for i in scene.marks.indices where canvas.selected.contains(scene.marks[i].id) {
          scene.marks[i].width = canvas.stroke
        }
      }
    }
  }
  func selectTool(_ tool: Tool) {
    canvas.tool = tool
    for (kind, button) in toolButtons { button.state = kind == tool ? .on : .off }
    status.stringValue = "\(tool.rawValue) selected · Drag on the image to use this tool"
    window?.makeFirstResponder(canvas)
  }
  func fit() {
    let size = canvas.enclosingScrollView?.contentSize ?? CGSize(width: 900, height: 600)
    canvas.setZoom(
      min(size.width / shot.scene.size.width, size.height / shot.scene.size.height) * 0.96)
  }
  func perform(_ action: () throws -> Void) {
    do { try action() } catch { StudioApp.shared.report(error) }
  }
  func configureCommands() {
    commands = Tool.allCases.filter {
      ![Tool.select, .arrow, .text, .rectangle, .highlight, .redact].contains($0)
    }.map { tool in
      (
        tool.rawValue,
        { [weak self] in
          self?.selectTool(tool)
        }
      )
    }
    commands += [
      ("Copy Text (OCR)", { [weak self] in self?.recognize("copy") }),
      ("Copy Text as One Line", { [weak self] in self?.recognize("line") }),
      ("Highlight Recognized Text", { [weak self] in self?.recognize("highlight") }),
      ("Find Sensitive Information", { [weak self] in self?.recognize("redact") }),
      ("Replace Recognized Text", { [weak self] in self?.recognize("replace") }),
      ("Read QR Code", { [weak self] in self?.qr() }),
      ("Crop Selection", { [weak self] in self?.canvas.crop() }),
      ("Remove Horizontal Strip", { [weak self] in self?.cut(true) }),
      ("Remove Vertical Strip", { [weak self] in self?.cut(false) }),
      ("Resize Image", { [weak self] in self?.resize() }),
      ("Rotate 90°", { [weak self] in self?.transform(rotation: true) }),
      ("Flip Horizontally", { [weak self] in self?.transform(rotation: false) }),
      (
        "Font Size",
        { [weak self] in
          guard let self,
            let text = input("Text size", message: "Pixels", value: String(Int(canvas.fontSize))),
            let n = Double(text), n >= 8, n <= 200
          else { return }
          canvas.fontSize = n
        }
      ),
      ("Group Selected", { [weak self] in self?.group() }),
      ("Ungroup Selected", { [weak self] in self?.group(ungroup: true) }),
      ("Bring Selected Forward", { [weak self] in self?.reorder(front: true) }),
      ("Send Selected Back", { [weak self] in self?.reorder(front: false) }),
      ("Align Selected Left", { [weak self] in self?.align() }),
      ("Add Image…", { [weak self] in self?.openImage() }),
      ("Paste Image", { [weak self] in self?.pasteImage() }),
      ("Arrange Images in Row", { [weak self] in self?.arrange(horizontal: true) }),
      ("Arrange Images in Column", { [weak self] in self?.arrange(horizontal: false) }),
      ("Overlay Last Image at 50%", { [weak self] in self?.overlay() }),
      (
        "Image Opacity…",
        { [weak self] in
          guard let self,
            let text = input(
              "Image opacity", message: "Selected image, or the last added image. Enter 0–100.",
              value: "50"), let value = Double(text), (0...100).contains(value)
          else { return }
          canvas.edit { scene in
            guard
              let index = scene.layers.firstIndex(where: { $0.id == self.canvas.selectedLayer })
                ?? scene.layers.indices.last
            else { return }
            scene.layers[index].opacity = value / 100
          }
        }
      ),
      ("Compare Images: Difference", { [weak self] in self?.difference() }),
      ("Export Before / After GIF", { [weak self] in self?.comparisonGIF() }),
      ("Presentation Background", { [weak self] in self?.background() }),
      (
        "Save Style Preset",
        { [weak self] in
          guard let self else { return }
          UserDefaults.standard.set(
            try? JSONEncoder().encode(shot.scene.backdrop), forKey: "backdropPreset")
          status.stringValue = "Style preset saved"
        }
      ),
      (
        "Apply Style Preset",
        { [weak self] in
          guard let self, let data = UserDefaults.standard.data(forKey: "backdropPreset"),
            let preset = try? JSONDecoder().decode(Backdrop.self, from: data)
          else { return }
          canvas.edit { $0.backdrop = preset }
        }
      ),
      ("Save Editable Project…", { [weak self] in self?.saveProject() }),
      ("Export JPEG…", { [weak self] in self?.export("jpg") }),
      ("Export PDF…", { [weak self] in self?.export("pdf") }),
      ("Copy Selected Color", { [weak self] in self?.copyColor() }),
      ("Measure Contrast", { [weak self] in self?.contrast() }),
      ("Export Options…", { [weak self] in self?.exportOptions() }),
      (
        "Preview Export",
        { [weak self] in
          guard let self else { return }
          perform { try StudioApp.shared.preview(self.shot) }
        }
      ),
    ]
  }
  func filterCommands(_ query: String) {
    more.removeAllItems()
    more.addItem(withTitle: "More…")
    for (i, command) in commands.enumerated()
    where query.isEmpty || command.0.localizedCaseInsensitiveContains(query) {
      more.addItem(withTitle: command.0)
      more.lastItem?.tag = i
    }
  }
  func controlTextDidChange(_ notification: Notification) { filterCommands(search.stringValue) }
  @objc func runMore(_ sender: NSPopUpButton) {
    guard sender.indexOfSelectedItem > 0, let i = sender.selectedItem?.tag else { return }
    commands[i].1()
    sender.selectItem(at: 0)
  }
  func currentImage() throws -> CGImage {
    try Renderer.image(shot.scene, store: shot.store, decorate: false)
  }
  func cut(_ horizontal: Bool) {
    guard let selection = canvas.selection else {
      status.stringValue = "Drag a selection with Select / Crop first"
      return
    }
    perform {
      canvas.flatten(try Renderer.cut(currentImage(), strip: selection, horizontal: horizontal))
    }
  }
  func resize() {
    guard
      let answer = input(
        "Resize image",
        message: "Width × height in pixels. This flattens edits; Undo restores them.",
        value: "\(Int(shot.scene.size.width)) x \(Int(shot.scene.size.height))")
    else { return }
    let parts = answer.lowercased().split(separator: "x").compactMap {
      Double($0.trimmingCharacters(in: .whitespaces))
    }
    guard parts.count == 2 else { return }
    perform {
      canvas.flatten(
        try Renderer.transformed(currentImage(), size: CGSize(width: parts[0], height: parts[1])))
      fit()
    }
  }
  func transform(rotation: Bool) {
    perform {
      let size = shot.scene.size
      canvas.flatten(
        try Renderer.transformed(
          currentImage(), size: rotation ? CGSize(width: size.height, height: size.width) : size,
          rotation: rotation, flip: !rotation))
      fit()
    }
  }
  func group(ungroup: Bool = false) {
    let id = UUID()
    canvas.edit { scene in
      for i in scene.marks.indices where canvas.selected.contains(scene.marks[i].id) {
        scene.marks[i].group = ungroup ? nil : id
      }
    }
  }
  func reorder(front: Bool) {
    canvas.edit { scene in
      let chosen = scene.marks.filter { canvas.selected.contains($0.id) }
      let others = scene.marks.filter { !canvas.selected.contains($0.id) }
      scene.marks = front ? others + chosen : chosen + others
    }
  }
  func align() {
    let marks = shot.scene.marks.filter { canvas.selected.contains($0.id) }
    guard let x = marks.map(\.rect.minX).min() else { return }
    canvas.edit { scene in
      for i in scene.marks.indices where canvas.selected.contains(scene.marks[i].id) {
        let dx = x - scene.marks[i].rect.minX
        scene.marks[i].rect.origin.x = x
        scene.marks[i].points = scene.marks[i].points.map { CGPoint(x: $0.x + dx, y: $0.y) }
        if let end = scene.marks[i].end { scene.marks[i].end = CGPoint(x: end.x + dx, y: end.y) }
      }
    }
  }
  func addImage(_ url: URL) { perform { try append(loadImage(url)) } }
  func append(_ image: CGImage) throws {
    let asset = try shot.store.add(image)
    canvas.edit { scene in
      let width = min(CGFloat(image.width), scene.size.width)
      let height = width * CGFloat(image.height) / CGFloat(image.width)
      scene.layers.append(
        Layer(asset: asset, rect: CGRect(x: 0, y: 0, width: width, height: height)))
    }
    status.stringValue = "Image added. More → Arrange Images or Overlay Last Image."
  }
  func openImage() {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.image]
    if panel.runModal() == .OK, let url = panel.url { addImage(url) }
  }
  func pasteImage() {
    perform {
      guard let image = NSImage(pasteboard: .general),
        let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
      else { throw StudioError("Clipboard does not contain an image") }
      try append(cg)
    }
  }
  func addCapture() {
    Task {
      do {
        window?.orderOut(nil)
        defer { window?.makeKeyAndOrderFront(nil) }
        guard let target = try await StudioApp.shared.capture.choose() else { return }
        try append(await StudioApp.shared.capture.capture(target))
      } catch { StudioApp.shared.report(error) }
    }
  }
  func arrange(horizontal: Bool) {
    canvas.edit { scene in
      var offset: CGFloat = 0
      var maxOther: CGFloat = 0
      for i in scene.layers.indices {
        let size = scene.layers[i].rect.size
        scene.layers[i].opacity = 1
        scene.layers[i].rect.origin =
          horizontal ? CGPoint(x: offset, y: 0) : CGPoint(x: 0, y: offset)
        offset += (horizontal ? size.width : size.height) + 24
        maxOther = max(maxOther, horizontal ? size.height : size.width)
      }
      scene.size =
        horizontal
        ? CGSize(width: max(1, offset - 24), height: maxOther)
        : CGSize(width: maxOther, height: max(1, offset - 24))
    }
    fit()
  }
  func overlay() {
    canvas.edit { scene in
      guard scene.layers.count > 1 else { return }
      scene.layers[scene.layers.count - 1].rect = scene.layers[0].rect
      scene.layers[scene.layers.count - 1].opacity = 0.5
    }
  }
  func difference() {
    perform {
      guard shot.scene.layers.count >= 2 else { throw StudioError("Add a second image first") }
      var first = shot.scene
      var second = shot.scene
      first.layers = [shot.scene.layers[0]]
      second.layers = [shot.scene.layers[1]]
      let a = try Renderer.image(first, store: shot.store, decorate: false)
      let b = try Renderer.image(second, store: shot.store, decorate: false)
      let ci = CIImage(cgImage: b).applyingFilter(
        "CIDifferenceBlendMode", parameters: [kCIInputBackgroundImageKey: CIImage(cgImage: a)])
      guard let result = Renderer.ci.createCGImage(ci, from: CIImage(cgImage: a).extent) else {
        return
      }
      canvas.flatten(result)
    }
  }
  func comparisonGIF() {
    perform {
      guard shot.scene.layers.count >= 2 else { throw StudioError("Add a second image first") }
      guard let url = chooseSave(extension: "gif") else { return }
      var frames: [CGImage] = []
      for layer in shot.scene.layers.prefix(2) {
        var scene = shot.scene
        scene.layers = [Layer(asset: layer.asset, rect: CGRect(origin: .zero, size: scene.size))]
        frames.append(try Renderer.image(scene, store: shot.store, maxSide: 1920))
      }
      try Renderer.gif(frames, to: url, delay: 0.9)
      status.stringValue = "Comparison saved"
    }
  }
  func background() {
    let alert = NSAlert()
    alert.messageText = "Presentation background"
    alert.informativeText = "Choose a restrained style. Padding and corners are adjustable."
    ["Gradient", "Solid", "Transparent", "Cancel"].forEach { alert.addButton(withTitle: $0) }
    let answer = alert.runModal()
    guard answer.rawValue < 1003 else { return }
    canvas.edit { scene in
      scene.backdrop.enabled = answer.rawValue != 1002
      if answer.rawValue == 1001 {
        scene.backdrop.first = canvas.ink
        scene.backdrop.second = canvas.ink
      } else {
        scene.backdrop.first = Backdrop().first
        scene.backdrop.second = Backdrop().second
      }
    }
    if shot.scene.backdrop.enabled,
      let s = input("Frame spacing", message: "Padding, corner radius (pixels)", value: "64, 20")
    {
      let values = s.split(separator: ",").compactMap {
        Double($0.trimmingCharacters(in: .whitespaces))
      }
      if values.count == 2, values.allSatisfy({ $0 >= 0 && $0 <= 500 }) {
        canvas.edit {
          $0.backdrop.padding = values[0]
          $0.backdrop.radius = values[1]
        }
      }
    }
    status.stringValue =
      "Background applies to preview/export; canvas shows original image for precise edits"
  }
  func saveProject() {
    guard
      confirm(
        "Save editable project?",
        "Projects retain original pixels and editable objects. Share a flattened PNG/JPEG when redactions must be permanent.",
        action: "Choose Location"), let url = chooseSave(extension: "posshot")
    else { return }
    perform {
      try shot.saveProject(to: url)
      window?.isDocumentEdited = false
    }
  }
  func export(_ ext: String) { perform { _ = try StudioApp.shared.save(shot, format: ext) } }
  func exportOptions() {
    guard
      let result = input(
        "Export options", message: "Maximum long edge (0 = native), JPEG quality 1–100",
        value: "0, 90")
    else { return }
    let values = result.split(separator: ",").compactMap {
      Double($0.trimmingCharacters(in: .whitespaces))
    }
    guard values.count == 2, values[0] >= 0, values[0] <= 60000, values[1] >= 1, values[1] <= 100
    else { return }
    UserDefaults.standard.set(values[0], forKey: "exportSide")
    UserDefaults.standard.set(values[1] / 100, forKey: "jpegQuality")
    perform {
      let image = try StudioApp.shared.exportImage(shot)
      let rep = NSBitmapImageRep(cgImage: image)
      let png = rep.representation(using: .png, properties: [:])?.count ?? 0
      let jpeg =
        rep.representation(using: .jpeg, properties: [.compressionFactor: values[1] / 100])?.count
        ?? 0
      status.stringValue =
        "\(image.width) × \(image.height) px · PNG \(ByteCountFormatter.string(fromByteCount:Int64(png),countStyle:.file)) · JPEG \(ByteCountFormatter.string(fromByteCount:Int64(jpeg),countStyle:.file))"
    }
  }
  func share() {
    guard let view = window?.contentView else { return }
    perform {
      let url = try StudioApp.shared.dragFile(shot)
      NSSharingServicePicker(items: [url]).show(relativeTo: .zero, of: view, preferredEdge: .minY)
    }
  }
  func copyColor() {
    guard let r = canvas.selection,
      let color = canvas.pixel(at: r.origin, exact: true)?.usingColorSpace(.sRGB)
    else {
      status.stringValue = "Select a pixel region first"
      return
    }
    let text = String(
      format: "#%02X%02X%02X", Int(color.redComponent * 255), Int(color.greenComponent * 255),
      Int(color.blueComponent * 255))
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
    status.stringValue = "Copied \(text)"
  }
  func contrast() {
    guard let r = canvas.selection,
      let a = canvas.pixel(at: r.origin, exact: true)?.usingColorSpace(.sRGB),
      let b = canvas.pixel(at: CGPoint(x: r.maxX, y: r.maxY), exact: true)?.usingColorSpace(.sRGB)
    else {
      status.stringValue = "Select between two colors to measure contrast"
      return
    }
    func luminance(_ c: NSColor) -> Double {
      let rgb = [c.redComponent, c.greenComponent, c.blueComponent].map { v in
        v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
      }
      return rgb[0] * 0.2126 + rgb[1] * 0.7152 + rgb[2] * 0.0722
    }
    let x = luminance(a)
    let y = luminance(b)
    status.stringValue = String(
      format: "WCAG contrast %.2f:1", (max(x, y) + 0.05) / (min(x, y) + 0.05))
  }
  func recognize(_ mode: String) {
    guard !busy else { return }
    busy = true
    status.stringValue = "Recognizing text locally…"
    let scene = shot.scene
    let store = shot.store
    let region = canvas.selection
    Task {
      defer { busy = false }
      do {
        let lines = try await ImageWorker.shared.run {
          let image = try Renderer.image(scene, store: store, decorate: false)
          return try VisionTools.recognize(image).filter {
            region == nil || region!.intersects($0.rect)
          }
        }
        if mode == "copy" || mode == "line" {
          let text = lines.map(\.text).joined(separator: mode == "line" ? " " : "\n")
          guard !text.isEmpty else { throw StudioError("No text found") }
          NSPasteboard.general.clearContents()
          NSPasteboard.general.setString(text, forType: .string)
          status.stringValue = "Text copied"
        } else if mode == "replace" {
          guard let line = lines.first,
            let replacement = input(
              "Replace text",
              message:
                "Select one text line first. Background fill works best on flat backgrounds.",
              value: line.text)
          else { return }
          canvas.edit { scene in
            scene.marks.append(
              Mark(
                tool: .erase, rect: line.rect.insetBy(dx: -2, dy: -2),
                ink: Ink(
                  canvas.pixel(at: CGPoint(x: max(0, line.rect.minX - 3), y: line.rect.minY))
                    ?? .white)))
            scene.marks.append(
              Mark(
                tool: .text, rect: line.rect, text: replacement, ink: canvas.ink,
                fontSize: max(8, line.rect.height * 0.85)))
          }
        } else {
          let chosen = mode == "redact" ? VisionTools.sensitive(lines) : lines
          guard !chosen.isEmpty else {
            throw StudioError(
              mode == "redact"
                ? "No patterns found. This does not guarantee the image is free of sensitive information."
                : "No text found")
          }
          if mode == "redact"
            && !confirm(
              "Review \(chosen.count) suggested redactions",
              chosen.map(\.text).joined(separator: "\n")
                + "\n\nDetection can miss information. Review the image after applying.",
              action: "Redact These Lines")
          {
            return
          }
          canvas.edit { scene in
            for line in chosen {
              scene.marks.append(
                Mark(
                  tool: mode == "redact" ? .redact : .highlight,
                  rect: line.rect.insetBy(dx: -2, dy: -2), ink: canvas.ink))
            }
          }
        }
      } catch {
        StudioApp.shared.report(error)
        status.stringValue = "Ready"
      }
    }
  }
  func qr() {
    guard !busy else { return }
    busy = true
    Task {
      defer { busy = false }
      do {
        let scene = shot.scene
        let store = shot.store
        let values = try await ImageWorker.shared.run {
          try VisionTools.barcodes(Renderer.image(scene, store: store, decorate: false))
        }
        guard !values.isEmpty else { throw StudioError("No QR code found") }
        if confirm("QR code contents", values.joined(separator: "\n"), action: "Copy") {
          NSPasteboard.general.clearContents()
          NSPasteboard.general.setString(values.joined(separator: "\n"), forType: .string)
        }
      } catch { StudioApp.shared.report(error) }
    }
  }
  func windowShouldClose(_ sender: NSWindow) -> Bool { !busy && StudioApp.shared.mayClose(shot) }
  func windowWillClose(_ notification: Notification) {
    canvas.changed = nil
    canvas.status = nil
    canvas.onDrop = nil
    canvas.preview = nil
    StudioApp.shared.release(self, shot: shot)
  }
}
