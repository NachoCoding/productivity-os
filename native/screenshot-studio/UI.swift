import AppKit
import UniformTypeIdentifiers

@MainActor final class ClickButton: NSButton {
  var actionBlock: () -> Void
  init(_ title: String, symbol: String? = nil, action: @escaping () -> Void) {
    actionBlock = action
    super.init(frame: .zero)
    self.title = title
    bezelStyle = .rounded
    target = self
    self.action = #selector(clicked)
    if let symbol {
      image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
      imagePosition = .imageLeading
    }
    let help = ["−": "Zoom out", "+": "Zoom in", "Fit": "Fit image to window", "Copy": "Copy image to clipboard", "Save": "Save image or editable project"]
    toolTip = help[title] ?? title
    setAccessibilityLabel(help[title] ?? title)
  }
  required init?(coder: NSCoder) { fatalError() }
  @objc func clicked() { actionBlock() }
}

@MainActor func row(_ views: [NSView], spacing: CGFloat = 8) -> NSStackView {
  let stack = NSStackView(views: views)
  stack.orientation = .horizontal
  stack.spacing = spacing
  stack.alignment = .centerY
  return stack
}
@MainActor func column(_ views: [NSView], spacing: CGFloat = 10) -> NSStackView {
  let stack = NSStackView(views: views)
  stack.orientation = .vertical
  stack.spacing = spacing
  stack.alignment = .leading
  return stack
}
@MainActor func label(_ text: String, size: CGFloat = 13, secondary: Bool = false) -> NSTextField {
  let view = NSTextField(wrappingLabelWithString: text)
  view.font = .systemFont(ofSize: size)
  if secondary { view.textColor = .secondaryLabelColor }
  return view
}
@MainActor final class ChromeBackground: NSView {
  override var isOpaque: Bool { true }
  override func draw(_ dirtyRect: NSRect) {
    NSColor.windowBackgroundColor.setFill()
    bounds.fill()
  }
  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    needsDisplay = true
  }
}
@MainActor func fill(_ child: NSView, in parent: NSView, inset: CGFloat = 16) {
  let background = ChromeBackground(frame: parent.bounds)
  background.autoresizingMask = [.width, .height]
  parent.addSubview(background, positioned: .below, relativeTo: nil)
  parent.addSubview(child)
  child.translatesAutoresizingMaskIntoConstraints = false
  NSLayoutConstraint.activate([
    child.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: inset),
    child.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -inset),
    child.topAnchor.constraint(equalTo: parent.topAnchor, constant: inset),
    child.bottomAnchor.constraint(equalTo: parent.bottomAnchor, constant: -inset),
  ])
}
@MainActor func input(_ title: String, message: String, value: String = "") -> String? {
  let alert = NSAlert()
  alert.messageText = title
  alert.informativeText = message
  alert.addButton(withTitle: "Apply")
  alert.addButton(withTitle: "Cancel")
  let field = NSTextField(string: value)
  field.frame = CGRect(x: 0, y: 0, width: 360, height: 28)
  alert.accessoryView = field
  alert.window.initialFirstResponder = field
  return alert.runModal() == .alertFirstButtonReturn ? field.stringValue : nil
}
@MainActor func confirm(_ title: String, _ message: String, action: String = "Apply") -> Bool {
  let alert = NSAlert()
  alert.messageText = title
  alert.informativeText = message
  alert.addButton(withTitle: action)
  alert.addButton(withTitle: "Cancel")
  return alert.runModal() == .alertFirstButtonReturn
}
@MainActor func chooseSave(extension ext: String) -> URL? {
  let panel = NSSavePanel()
  panel.allowedContentTypes = [UTType(filenameExtension: ext) ?? .data]
  panel.nameFieldStringValue =
    "Screenshot \(Date().formatted(.iso8601).replacingOccurrences(of: ":", with: "-"))"
  if let path = UserDefaults.standard.string(forKey: "saveFolder") {
    panel.directoryURL = URL(fileURLWithPath: path)
  }
  guard panel.runModal() == .OK, let url = panel.url else { return nil }
  UserDefaults.standard.set(url.deletingLastPathComponent().path, forKey: "saveFolder")
  return url
}

@MainActor final class FileDragView: NSImageView, NSDraggingSource {
  var file: (() throws -> URL)?
  var onDrag: (() -> Void)?
  override func mouseDown(with event: NSEvent) {
    guard let file else { return }
    do {
      let url = try file()
      let item = NSDraggingItem(pasteboardWriter: url as NSURL)
      item.setDraggingFrame(bounds, contents: image)
      beginDraggingSession(with: [item], event: event, source: self)
    } catch { StudioApp.shared.report(error) }
  }
  func draggingSession(
    _ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext
  ) -> NSDragOperation { .copy }
  func draggingSession(
    _ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation
  ) { if operation != [] { onDrag?() } }
}

/// Esc acts like the close button: an unused capture still gets the save prompt, never a silent discard.
@MainActor final class QuickActionsWindow: NSWindow {
  override func cancelOperation(_ sender: Any?) { performClose(sender) }
}

/// A transient, click-through, non-activating message (e.g. a capture that did not start in time).
@MainActor final class NoticePanel {
  private var panel: NSPanel?
  private let text = label("", size: 13)
  private var shown = 0
  var hidden: () -> Void = {}
  var isShowing: Bool { panel?.isVisible == true }
  func show(_ message: String, seconds: Double = 4) {
    let panel = self.panel ?? build()
    self.panel = panel
    text.stringValue = message
    let mouse = NSEvent.mouseLocation
    if let frame = (NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main)?.visibleFrame {
      panel.setFrame(
        CGRect(x: frame.midX - 220, y: frame.maxY - 88, width: 440, height: 64), display: false)
    }
    panel.orderFrontRegardless()
    NSAccessibility.post(
      element: NSApp as Any, notification: .announcementRequested,
      userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    shown += 1
    let current = shown
    DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
      guard let self, shown == current else { return }
      self.panel?.orderOut(nil)
      hidden()
    }
  }
  private func build() -> NSPanel {
    let panel = NSPanel(
      contentRect: CGRect(x: 0, y: 0, width: 440, height: 64),
      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
    panel.level = .statusBar
    panel.isFloatingPanel = true
    panel.hidesOnDeactivate = false
    panel.ignoresMouseEvents = true
    panel.isReleasedWhenClosed = false
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = true
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
    let background = NSVisualEffectView()
    background.material = .hudWindow
    background.blendingMode = .behindWindow
    background.state = .active
    background.wantsLayer = true
    background.layer?.cornerRadius = 12
    background.layer?.masksToBounds = true
    panel.contentView = background
    text.alignment = .center
    text.translatesAutoresizingMaskIntoConstraints = false
    background.addSubview(text)
    NSLayoutConstraint.activate([
      text.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 16),
      text.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -16),
      text.centerYAnchor.constraint(equalTo: background.centerYAnchor),
    ])
    return panel
  }
}

@MainActor final class PreviewController: NSWindowController, NSWindowDelegate {
  let shot: StudioDocument
  var consumed = false
  init(_ shot: StudioDocument) throws {
    self.shot = shot
    let window = QuickActionsWindow(
      contentRect: CGRect(x: 0, y: 0, width: 470, height: 310),
      styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    window.title = "Screenshot · Quick Actions"
    window.isReleasedWhenClosed = false
    window.level = .floating
    super.init(window: window)
    window.delegate = self
    let preview = FileDragView()
    preview.imageScaling = .scaleProportionallyUpOrDown
    let image = try Renderer.image(shot.scene, store: shot.store, maxSide: 900)
    preview.image = NSImage(cgImage: image, size: .zero)
    preview.heightAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true
    preview.file = { [weak self] in
      guard let self else { throw StudioError("Capture closed") }
      return try StudioApp.shared.dragFile(self.shot)
    }
    preview.onDrag = { [weak self] in self?.consumed = true }
    let buttons = row([
      ClickButton("Copy", symbol: "doc.on.doc") { [weak self] in
        self?.perform {
          try StudioApp.shared.copy(shot)
          self?.consumed = true
        }
      },
      ClickButton("Save", symbol: "square.and.arrow.down") { [weak self] in
        self?.perform { if try StudioApp.shared.save(shot) { self?.consumed = true } }
      },
      ClickButton("Mark Up", symbol: "pencil.tip") { [weak self] in
        StudioApp.shared.edit(shot)
        self?.consumed = true
        self?.window?.close()
      },
      ClickButton("Pin", symbol: "pin") { [weak self] in
        self?.perform {
          try StudioApp.shared.pin(shot)
          self?.consumed = true
          self?.window?.close()
        }
      },
    ])
    let stack = column([
      preview, buttons,
      label(
        "Drag the preview into another app. Nothing is saved automatically.", size: 11,
        secondary: true),
    ])
    preview.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    fill(stack, in: window.contentView!)
    window.center()
  }
  required init?(coder: NSCoder) { fatalError() }
  func perform(_ action: () throws -> Void) {
    do { try action() } catch { StudioApp.shared.report(error) }
  }
  func windowShouldClose(_ sender: NSWindow) -> Bool {
    consumed || StudioApp.shared.mayClose(shot)
  }
  func windowWillClose(_ notification: Notification) { StudioApp.shared.release(self, shot: shot) }
}

@MainActor final class PinController: NSWindowController, NSWindowDelegate {
  let shot: StudioDocument
  init(_ shot: StudioDocument) throws {
    self.shot = shot
    let image = try Renderer.image(shot.scene, store: shot.store, maxSide: 1600)
    let ratio = CGFloat(image.height) / CGFloat(image.width)
    let window = NSPanel(
      contentRect: CGRect(x: 0, y: 0, width: 420, height: min(700, 420 * ratio) + 44),
      styleMask: [.titled, .closable, .resizable, .utilityWindow], backing: .buffered, defer: false)
    window.title = "Pinned Reference"
    window.isReleasedWhenClosed = false
    window.level = .floating
    window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    super.init(window: window)
    window.delegate = self
    let view = NSImageView()
    view.image = NSImage(cgImage: image, size: .zero)
    view.imageScaling = .scaleProportionallyUpOrDown
    let slider = NSSlider(
      value: 1, minValue: 0.15, maxValue: 1, target: self, action: #selector(opacity(_:)))
    slider.setAccessibilityLabel("Reference opacity")
    let controls = row([
      label("Opacity"), slider,
      ClickButton("Click Through") { [weak self] in
        self?.window?.ignoresMouseEvents = true
        StudioApp.shared.ensurePinMenu()
      },
    ])
    let stack = column([controls, view])
    view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    view.heightAnchor.constraint(greaterThanOrEqualToConstant: 80).isActive = true
    fill(stack, in: window.contentView!, inset: 8)
    window.center()
  }
  required init?(coder: NSCoder) { fatalError() }
  @objc func opacity(_ sender: NSSlider) { window?.alphaValue = sender.doubleValue }
  func windowWillClose(_ notification: Notification) { StudioApp.shared.release(self, shot: shot) }
}
