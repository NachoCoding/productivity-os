import AppKit
import Carbon
import Quartz
import QuickLookThumbnailing
import UniformTypeIdentifiers

@MainActor final class ShelfButton: NSButton {
  let handler: () -> Void
  init(_ symbol: String, help: String, action: @escaping () -> Void) {
    handler = action
    super.init(frame: .zero)
    image = NSImage(systemSymbolName: symbol, accessibilityDescription: help)
    isBordered = false; bezelStyle = .recessed
    imagePosition = .imageOnly; toolTip = help
    setAccessibilityLabel(help)
    target = self; self.action = #selector(invoke)
  }
  required init?(coder: NSCoder) { fatalError() }
  @objc func invoke() { handler() }
}
@MainActor final class ShelfPanel: NSPanel {
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }
}
@MainActor final class ShelfDropView: NSVisualEffectView {
  weak var controller: ShelfController?
  /// Optional owned-fixture diagnostics; production does not install an observer.
  var dragObserver: ((String, [String], UInt) -> Void)?
  private var receivingDrag = false
  let glow = NSView()
  var highlighted = false {
    didSet {
      guard highlighted != oldValue else { return }
      NSAnimationContext.runAnimationGroup { context in
        context.duration = 0.15
        glow.animator().alphaValue = highlighted ? 1 : 0
      }
    }
  }
  static func mask(_ size: NSSize, radius: CGFloat) -> NSImage {
    let image = NSImage(size: size, flipped: false) { rect in
      NSColor.black.setFill()
      NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
      return true
    }
    image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
    image.resizingMode = .stretch
    return image
  }
  override init(frame: NSRect) {
    super.init(frame: frame)
    material = .hudWindow; blendingMode = .behindWindow; state = .active
    // maskImage gives antialiased corners; a layer cornerRadius on a vibrancy view leaves jaggies.
    maskImage = Self.mask(NSSize(width: 48, height: 48), radius: 20)
    glow.frame = bounds; glow.autoresizingMask = [.width, .height]
    glow.wantsLayer = true
    glow.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.18).cgColor
    glow.alphaValue = 0
    addSubview(glow)
    registerForDraggedTypes(ShelfIngest.dragTypes)
  }
  required init?(coder: NSCoder) { fatalError() }
  func acceptsDrop(types: [NSPasteboard.PasteboardType], sourceShelfID: UUID?) -> Bool {
    guard let controller, sourceShelfID != controller.id else { return false }
    return !Set(types).isDisjoint(with: ShelfIngest.dragTypes)
      && controller.items.count + controller.pendingImages < ShelfStore.maxItems
  }
  private func operation(_ sender: NSDraggingInfo) -> NSDragOperation {
    dragObserver?("update", (sender.draggingPasteboard.types ?? []).map(\.rawValue), sender.draggingSourceOperationMask.rawValue)
    let accepted = acceptsDrop(types: sender.draggingPasteboard.types ?? [], sourceShelfID: (sender.draggingSource as? ShelfTile)?.controller?.id)
      && sender.draggingSourceOperationMask.contains(.copy)
    highlighted = accepted
    if accepted && !receivingDrag { receivingDrag = true; controller?.beginInteraction() }
    else if !accepted { finishReceiving() }
    return accepted ? .copy : []
  }
  override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
    operation(sender)
  }
  override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { operation(sender) }
  private func finishReceiving() {
    highlighted = false
    guard receivingDrag else { return }
    receivingDrag = false; controller?.endInteraction()
  }
  override func draggingExited(_ sender: NSDraggingInfo?) { finishReceiving() }
  override func draggingEnded(_ sender: NSDraggingInfo) { finishReceiving() }
  override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { !operation(sender).isEmpty }
  override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
    dragObserver?("perform", (sender.draggingPasteboard.types ?? []).map(\.rawValue), sender.draggingSourceOperationMask.rawValue)
    let accepted = !operation(sender).isEmpty
    defer { finishReceiving() }
    return accepted && (controller?.ingest(sender.draggingPasteboard, preferFileReferences: sender.draggingSource is ShelfTile) ?? false)
  }
}
@MainActor final class ShelfTile: NSView, NSDraggingSource {
  weak var controller: ShelfController?
  var ids: [UUID] = []
  /// Real thumbnail used as the drag image once Quick Look has produced it.
  var preview: NSImage?
  var start: NSPoint = .zero
  private var collapseOnMouseUp: UUID?
  private var dragging = false
  private var dragLease: UUID?
  override var acceptsFirstResponder: Bool { true }
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
  override var needsPanelToBecomeKey: Bool { true }
  override var mouseDownCanMoveWindow: Bool { false }
  override func hitTest(_ point: NSPoint) -> NSView? { super.hitTest(point) == nil ? nil : self }
  override func mouseDown(with event: NSEvent) {
    start = convert(event.locationInWindow, from: nil)
    dragging = false; collapseOnMouseUp = nil
    controller?.beginInteraction()
    if ids.count == 1, let controller {
      if event.modifierFlags.contains(.command) { controller.select(ids[0], extend: true) }
      else if controller.selected.contains(ids[0]) { collapseOnMouseUp = ids[0] }
      else { controller.select(ids[0], extend: false) }
    }
    if event.clickCount == 2 {
      collapseOnMouseUp = nil
      controller?.endInteraction(); controller?.quickLook()
    }
  }
  override func mouseUp(with event: NSEvent) {
    if !dragging, let id = collapseOnMouseUp { controller?.select(id, extend: false) }
    collapseOnMouseUp = nil; controller?.endInteraction()
  }
  func dragItems() -> [ShelfItem] {
    guard let controller else { return [] }
    return ids.count == 1 && controller.selected.contains(ids[0]) ? controller.chosen : controller.items.filter { ids.contains($0.id) }
  }
  override func mouseDragged(with event: NSEvent) {
    let point = convert(event.locationInWindow, from: nil)
    guard !dragging, hypot(point.x - start.x, point.y - start.y) > 4, let controller else { return }
    let items = dragItems()
    let values = items.compactMap { item -> NSDraggingItem? in
      guard let writer = controller.writer(item) else { return nil }
      let result = NSDraggingItem(pasteboardWriter: writer)
      let icon = (items.count == 1 ? preview : nil) ?? item.resolvedURL().map { NSWorkspace.shared.icon(forFile: $0.path) }
        ?? NSImage(systemSymbolName: item.kind == .link ? "link" : "doc.text", accessibilityDescription: nil)!
      let side: CGFloat = items.count == 1 && preview != nil ? 72 : 48
      let aspect = icon.size.height > 0 ? icon.size.width / icon.size.height : 1
      let size = aspect >= 1 ? NSSize(width: side, height: side / aspect) : NSSize(width: side * aspect, height: side)
      result.setDraggingFrame(NSRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width, height: size.height), contents: icon)
      return result
    }
    guard !values.isEmpty else { controller.updateStatus(); return }
    dragging = true; collapseOnMouseUp = nil
    let lease = UUID(); dragLease = lease
    controller.app.activeDragURLs[lease] = items.compactMap { $0.resolvedURL() }
    beginDraggingSession(with: values, event: event, source: self)
  }
  func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
    .copy
  }
  func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
    dragging = false
    if let dragLease { controller?.app.activeDragURLs.removeValue(forKey: dragLease) }
    dragLease = nil
    controller?.endInteraction(); controller?.app.cleanAttachments()
  }
  override func rightMouseDown(with event: NSEvent) {
    if ids.count == 1 && controller?.selected.contains(ids[0]) != true { controller?.select(ids[0], extend: false) }
    if let menu = controller?.actionMenu() { NSMenu.popUpContextMenu(menu, with: event, for: self) }
  }
}

@MainActor final class ShelfController: NSWindowController, NSWindowDelegate, @preconcurrency QLPreviewPanelDataSource, QLPreviewPanelDelegate {
  unowned let app: DropShelfApp
  let id: UUID
  let presentation: ShelfPresentationState
  var display: ShelfDisplay?
  var expanded: Bool {
    get { presentation.expanded }
    set { presentation.expanded = newValue }
  }
  var selected: Set<UUID> {
    get { presentation.selected }
    set { presentation.selected = newValue }
  }
  var previewURLs: [URL] = []
  var sharePicker: NSSharingServicePicker?
  var previewDirectory: URL?
  var message: String? {
    get { presentation.message }
    set { presentation.message = newValue }
  }
  private(set) var rootView: ShelfDropView?
  let scrollView = NSScrollView(), gridView = ShelfGridView()
  let pile = ShelfTile(), summaryLabel = NSTextField(labelWithString: "")
  private(set) var tiles: [UUID: ShelfTile] = [:]
  private var tileImages: [UUID: NSImageView] = [:]
  private var stackImages: [UUID: NSImageView] = [:]
  private var iconLoaded = Set<UUID>()
  private var renderedItems: [ShelfItem] = []
  private var displayedExpanded = false
  private var stackIDs: [UUID] = []
  private var controls: [String: ShelfButton] = [:]
  private let titleLabel = NSTextField(labelWithString: ""), colorDot = NSView()
  private let emptyImage = NSImageView(), emptyLabel = NSTextField(labelWithString: "")
  private let progress = NSProgressIndicator()
  /// The visible items whose icons and thumbnails were last applied; nil after views were rebuilt.
  private var thumbnailVisible: Set<UUID>?
  private var thumbnailScale: CGFloat = 0
  private(set) var thumbnailPasses = 0
  private(set) var activeGesture = false
  private(set) var deferredRender = false
  private var hasPresented = false
  var shelf: Shelf? { app.store?.shelves.first { $0.id == id } }
  var items: [ShelfItem] { shelf?.items ?? [] }
  /// Outgoing actions (drag, copy, Quick Look, share, export) use the whole stack when nothing is selected.
  var chosen: [ShelfItem] { selected.isEmpty ? items : items.filter { selected.contains($0.id) } }
  /// Removal only ever uses an explicit selection.
  var selectedItems: [ShelfItem] { items.filter { selected.contains($0.id) } }
  init(app: DropShelfApp, id: UUID, presentation: ShelfPresentationState? = nil, display: ShelfDisplay? = nil) {
    self.app = app; self.id = id
    self.presentation = presentation ?? ShelfPresentationState(); self.display = display
    let panel = ShelfPanel(contentRect: NSRect(x: 0, y: 0, width: 280, height: 216), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
    panel.hidesOnDeactivate = false
    panel.becomesKeyOnlyIfNeeded = false
    panel.isReleasedWhenClosed = false; panel.level = .floating
    panel.isMovableByWindowBackground = true
    panel.collectionBehavior = [.canJoinAllSpaces, .canJoinAllApplications, .fullScreenAuxiliary]
    super.init(window: panel)
    panel.delegate = self
    render()
  }
  required init?(coder: NSCoder) { fatalError() }
  private func screen(near point: NSPoint? = nil) -> NSScreen? {
    let screens = NSScreen.screens
    let preferred = window?.screen.flatMap { current in screens.firstIndex { $0 === current } }
    guard let index = ShelfPlacement.screenIndex(frames: screens.map(\.frame), near: point, preserving: window?.frame, preferred: preferred) else { return nil }
    return screens[index]
  }
  func present(near point: NSPoint? = nil, activate: Bool = true) {
    if let window, let bounds = display?.visibleFrame ?? screen(near: point)?.visibleFrame {
      let size = ShelfPlacement.preferredSize(expanded: expanded, in: bounds)
      window.setFrame(ShelfPlacement.frame(size: size, in: bounds, near: point, preserving: hasPresented && point == nil ? window.frame : nil), display: false)
      render()
    }
    hasPresented = true
    window?.orderFrontRegardless()
    // A non-activating panel takes the keyboard without activating Drop Shelf, so the frontmost
    // app keeps its menu bar and window order and nothing waits on an app switch.
    if activate { window?.makeKeyAndOrderFront(nil) }
  }
  /// Removes this display copy from screen for good.
  func retire() {
    closePreview(); window?.orderOut(nil)
    presentation.thumbnails.remove(self)
  }
  /// Dialogs and Quick Look need Drop Shelf active; only explicit user actions do this.
  private func prepareForDialog() {
    NSApp.activate(ignoringOtherApps: true)
    window?.makeKey()
  }
  func windowDidMove(_ notification: Notification) {
    // Each monitor already has a copy. Keep this panel on its assigned monitor,
    // including when the user drags its header toward the display boundary.
    guard let display, let window, !updatingViews, app.displayProvider().contains(display) else { return }
    let frame = ShelfPlacement.frame(size: window.frame.size, in: display.visibleFrame, preserving: window.frame)
    if frame != window.frame { window.setFrame(frame, display: false) }
  }
  /// A small paper card showing a text snippet or a link's host, like Dropover's text items.
  func textCard(_ item: ShelfItem, frame: NSRect) -> NSView {
    let card = NSView(frame: frame)
    card.wantsLayer = true
    card.layer?.cornerRadius = 8
    card.layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
    let link = item.kind == .link
    let host = URL(string: item.value.trimmingCharacters(in: .whitespacesAndNewlines))?.host
    if link {
      let glyph = NSImageView(frame: NSRect(x: (frame.width - 26) / 2, y: frame.height - 36, width: 26, height: 26))
      glyph.image = NSImage(systemSymbolName: "link", accessibilityDescription: "Link")
      glyph.contentTintColor = .controlAccentColor
      card.addSubview(glyph)
    }
    let label = NSTextField(wrappingLabelWithString: link ? (host ?? item.label) : String(item.value.prefix(800)).trimmingCharacters(in: .whitespacesAndNewlines))
    label.font = .systemFont(ofSize: link ? 10 : 8.5, weight: link ? .medium : .regular)
    label.textColor = .labelColor
    label.alignment = link ? .center : .left
    label.maximumNumberOfLines = link ? 2 : 6
    label.lineBreakMode = .byTruncatingTail
    label.frame = link ? NSRect(x: 4, y: 6, width: frame.width - 8, height: 26) : NSRect(x: 6, y: 5, width: frame.width - 12, height: frame.height - 10)
    card.addSubview(label)
    return card
  }
  /// Thumbnail with softly rounded corners for the compact stack.
  static func rounded(_ image: NSImage) -> NSImage {
    let size = image.size
    guard size.width > 0, size.height > 0 else { return image }
    return NSImage(size: size, flipped: false) { rect in
      let radius = min(rect.width, rect.height) * 0.08
      NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).addClip()
      image.draw(in: rect)
      return true
    }
  }
  func text(_ value: String, frame: NSRect, size: CGFloat = 12, secondary: Bool = false) -> NSTextField {
    let label = NSTextField(labelWithString: value)
    label.frame = frame; label.font = .systemFont(ofSize: size)
    label.textColor = secondary ? .secondaryLabelColor : .labelColor
    label.lineBreakMode = .byTruncatingTail
    label.toolTip = value
    return label
  }
  func button(_ symbol: String, help: String, x: CGFloat, y: CGFloat, in parent: NSView, action: @escaping () -> Void) {
    let view = ShelfButton(symbol, help: help, action: action)
    view.frame = NSRect(x: x, y: y, width: 28, height: 28)
    if ["eye", "square.and.arrow.up", "doc.on.doc"].contains(symbol) { view.isEnabled = !items.isEmpty }
    parent.addSubview(view)
  }
  private var updatingViews = false
  private func buildChrome() {
    guard rootView == nil, let window else { return }
    let root = ShelfDropView(frame: window.contentView?.bounds ?? .zero)
    root.controller = self; rootView = root; window.contentView = root
    func control(_ key: String, _ symbol: String, _ help: String, _ action: @escaping () -> Void) {
      let button = ShelfButton(symbol, help: help, action: action)
      controls[key] = button; root.addSubview(button)
    }
    control("close", "xmark", "Close shelf (kept in Recent)") { [weak self] in self?.closeShelf() }
    control("pin", "pin", "Pin shelf") { [weak self] in self?.change { $0.pinned.toggle() } }
    control("expand", "square.grid.2x2", "Show items") { [weak self] in
      guard let self else { return }; self.expanded = !self.displayedExpanded; self.app.renderShelf(self.id)
    }
    control("actions", "ellipsis.circle", "Shelf actions") { [weak self] in
      guard let self, let root = self.rootView else { return }
      self.actionMenu().popUp(positioning: nil, at: NSPoint(x: root.bounds.width - 30, y: root.bounds.height - 40), in: root)
    }
    control("add", "plus", "Add files") { [weak self] in self?.addFiles() }
    control("paste", "doc.on.clipboard", "Add clipboard") { [weak self] in _ = self?.ingest(.general) }
    control("preview", "eye", "Quick Look (Space)") { [weak self] in self?.quickLook() }
    control("share", "square.and.arrow.up", "Share") { [weak self] in self?.share() }
    control("copy", "doc.on.doc", "Copy items") { [weak self] in self?.copyItems() }
    colorDot.wantsLayer = true; colorDot.layer?.cornerRadius = 3.5; root.addSubview(colorDot)
    titleLabel.font = .systemFont(ofSize: 13, weight: .semibold); titleLabel.lineBreakMode = .byTruncatingTail
    root.addSubview(titleLabel)
    summaryLabel.font = .systemFont(ofSize: 11); summaryLabel.textColor = .secondaryLabelColor
    summaryLabel.alignment = .center; summaryLabel.lineBreakMode = .byTruncatingTail; root.addSubview(summaryLabel)
    emptyImage.image = NSImage(systemSymbolName: "tray.and.arrow.down", accessibilityDescription: "Drop files here")
    emptyImage.contentTintColor = .secondaryLabelColor; root.addSubview(emptyImage)
    emptyLabel.font = .systemFont(ofSize: 12); emptyLabel.alignment = .center; root.addSubview(emptyLabel)
    progress.style = .spinning; progress.controlSize = .small; progress.isDisplayedWhenStopped = false; root.addSubview(progress)
    scrollView.drawsBackground = false; scrollView.hasVerticalScroller = true; scrollView.scrollerStyle = .overlay
    scrollView.documentView = gridView; root.addSubview(scrollView)
    scrollView.contentView.postsBoundsChangedNotifications = true
    NotificationCenter.default.addObserver(self, selector: #selector(visibleAreaChanged), name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
    pile.controller = self; root.addSubview(pile)
  }
  func beginInteraction() { activeGesture = true }
  func endInteraction() {
    activeGesture = false
    if deferredRender { deferredRender = false; render() }
    app.synchronizeDisplays()
  }
  func render() {
    guard let window, let shelf else { return }
    let current = shelf.items
    selected.formIntersection(Set(current.map(\.id)))
    if activeGesture { deferredRender = true; updateStatus(); return }
    updatingViews = true
    defer { updatingViews = false; updateThumbnails() }
    buildChrome()
    guard let root = rootView else { return }
    let bounds = display?.visibleFrame ?? screen()?.visibleFrame
    let size = ShelfPlacement.preferredSize(expanded: expanded, in: bounds)
    let effectiveExpanded = size.width > 280
    if let bounds { window.setFrame(ShelfPlacement.frame(size: size, in: bounds, preserving: window.frame), display: false) }
    else { window.setContentSize(size) }
    let width = size.width, height = size.height
    root.frame = NSRect(origin: .zero, size: size)
    window.title = "Drop Shelf — \(shelf.name)"
    titleLabel.stringValue = shelf.name; titleLabel.toolTip = shelf.name
    titleLabel.frame = NSRect(x: 57, y: height - 34, width: width - 160, height: 20)
    colorDot.frame = NSRect(x: 44, y: height - 27.5, width: 7, height: 7)
    colorDot.layer?.backgroundColor = [NSColor.controlAccentColor, .systemOrange, .systemPink, .systemGreen, .systemPurple][shelf.color % 5].cgColor
    for (key, x, y) in [("close", 9.0, height - 38), ("pin", width - 99, height - 38), ("expand", width - 69, height - 38),
      ("actions", width - 39, height - 38), ("add", 16, 8), ("paste", 53, 8), ("preview", width / 2 - 14, 8), ("share", width - 81, 8), ("copy", width - 44, 8)] {
      controls[key]?.frame = NSRect(x: x, y: y, width: 28, height: 28)
    }
    controls["pin"]?.image = NSImage(systemSymbolName: shelf.pinned ? "pin.fill" : "pin", accessibilityDescription: "Pin shelf")
    let expandHelp = effectiveExpanded ? "Collapse shelf" : "Show items"
    controls["expand"]?.image = NSImage(systemSymbolName: effectiveExpanded ? "rectangle.compress.vertical" : "square.grid.2x2", accessibilityDescription: expandHelp)
    controls["expand"]?.toolTip = expandHelp; controls["expand"]?.setAccessibilityLabel(expandHelp)
    summaryLabel.frame = NSRect(x: 24, y: 39, width: width - 48, height: 18)
    progress.frame = NSRect(x: 6, y: 40, width: 15, height: 15)
    emptyImage.frame = NSRect(x: width / 2 - 27, y: height / 2 - 17, width: 54, height: 54)
    emptyLabel.frame = NSRect(x: 15, y: height / 2 - 47, width: width - 30, height: 20)
    let visible = scrollView.documentVisibleRect
    let anchor = tiles.values.filter { $0.frame.intersects(visible) }.min { $0.frame.minY < $1.frame.minY }
    let anchorID = anchor?.ids.first, offset = (anchor?.frame.minY ?? visible.minY) - visible.minY
    let changed = current != renderedItems
    let modeChanged = displayedExpanded != effectiveExpanded
    scrollView.frame = NSRect(x: 10, y: 59, width: width - 20, height: height - 109)
    pile.frame = NSRect(x: 22, y: 62, width: width - 44, height: height - 110)
    displayedExpanded = effectiveExpanded
    scrollView.isHidden = !effectiveExpanded || current.isEmpty
    pile.isHidden = effectiveExpanded || current.isEmpty
    emptyImage.isHidden = !current.isEmpty; emptyLabel.isHidden = !current.isEmpty
    if !changed && !modeChanged {
      updateSelection(); updateStatus(); return
    }
    if changed {
      let ids = Set(current.map(\.id))
      for id in Array(tiles.keys) where !ids.contains(id) { tiles.removeValue(forKey: id)?.removeFromSuperview(); tileImages.removeValue(forKey: id) }
      presentation.forget(keeping: ids); iconLoaded.formIntersection(ids)
    }
    if effectiveExpanded {
      let oldItems = Dictionary(uniqueKeysWithValues: renderedItems.map { ($0.id, $0) })
      for (index, item) in current.enumerated() {
        if tiles[item.id] == nil || oldItems[item.id] != item {
          tiles.removeValue(forKey: item.id)?.removeFromSuperview()
          let tile = makeTile(item); tiles[item.id] = tile; gridView.addSubview(tile)
        }
        tiles[item.id]?.frame = NSRect(x: CGFloat(index % 3) * 138 + 2, y: CGFloat(index / 3) * 117, width: 134, height: 112)
      }
      gridView.frame = NSRect(x: 0, y: 0, width: width - 20, height: max(scrollView.contentSize.height, ceil(CGFloat(current.count) / 3) * 117))
      let desiredY = anchorID.flatMap { tiles[$0]?.frame.minY }.map { $0 - offset } ?? visible.minY
      let y = min(max(0, desiredY), max(0, gridView.bounds.height - scrollView.contentSize.height))
      scrollView.contentView.scroll(to: NSPoint(x: 0, y: y)); scrollView.reflectScrolledClipView(scrollView.contentView)
    }
    if !effectiveExpanded && (changed || modeChanged || stackIDs.isEmpty) { renderStack(current) }
    renderedItems = current
    updateSelection(); updateStatus()
  }
  private func makeTile(_ item: ShelfItem) -> ShelfTile {
    thumbnailVisible = nil
    let tile = ShelfTile(frame: NSRect(x: 0, y: 0, width: 134, height: 112))
    tile.controller = self; tile.ids = [item.id]; tile.wantsLayer = true; tile.layer?.cornerRadius = 10
    if item.url != nil {
      let image = NSImageView(frame: NSRect(x: 39, y: 43, width: 56, height: 56))
      image.imageScaling = .scaleProportionallyUpOrDown
      image.image = NSImage(systemSymbolName: item.kind == .image ? "photo" : "doc", accessibilityDescription: nil)
      tileImages[item.id] = image; tile.addSubview(image); iconLoaded.remove(item.id)
    } else { tile.addSubview(textCard(item, frame: NSRect(x: 42, y: 42, width: 50, height: 60))) }
    let label = text(item.label, frame: NSRect(x: 6, y: 21, width: 122, height: 18), size: 11)
    label.alignment = .center; tile.addSubview(label)
    let subtitle = text(item.kind.rawValue.capitalized, frame: NSRect(x: 6, y: 5, width: 122, height: 16), size: 10, secondary: true)
    subtitle.alignment = .center; subtitle.identifier = NSUserInterfaceItemIdentifier("subtitle"); tile.addSubview(subtitle)
    tile.setAccessibilityElement(true); tile.setAccessibilityRole(.button); tile.setAccessibilityLabel(item.label)
    return tile
  }
  private func renderStack(_ current: [ShelfItem]) {
    thumbnailVisible = nil
    for view in pile.subviews { view.removeFromSuperview() }
    stackImages.removeAll(); pile.preview = nil; pile.ids = current.map(\.id); stackIDs = pile.ids
    let stack = Array(current.suffix(3).reversed()), side: CGFloat = 78
    let center = NSPoint(x: pile.bounds.midX, y: pile.bounds.midY)
    for (index, item) in stack.enumerated().reversed() {
      let frame = NSRect(x: center.x - side / 2, y: center.y - side / 2, width: side, height: side)
      let card: NSView
      if item.url != nil {
        let image = NSImageView(frame: frame); image.imageScaling = .scaleProportionallyUpOrDown
        image.image = NSImage(systemSymbolName: item.kind == .image ? "photo" : "doc", accessibilityDescription: nil)
        stackImages[item.id] = image; card = image; iconLoaded.remove(item.id)
      } else { card = textCard(item, frame: frame.insetBy(dx: 10, dy: 1)) }
      card.wantsLayer = true
      let shadow = NSShadow(); shadow.shadowBlurRadius = 6; shadow.shadowOffset = NSSize(width: 0, height: -2)
      shadow.shadowColor = NSColor.black.withAlphaComponent(0.28); card.shadow = shadow
      card.frameCenterRotation = [0.0, -7, 7][index]; pile.addSubview(card)
    }
    if current.count > 1 {
      let label = NSTextField(labelWithString: "\(current.count)")
      label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .bold); label.textColor = .white; label.alignment = .center
      let width = max(20, ceil(label.intrinsicContentSize.width) + 12)
      let badge = NSView(frame: NSRect(x: center.x + side / 2 - width / 2 + 4, y: center.y + side / 2 - 14, width: width, height: 20))
      badge.wantsLayer = true; badge.layer?.backgroundColor = NSColor.controlAccentColor.cgColor; badge.layer?.cornerRadius = 10
      label.frame = NSRect(x: 0, y: (20 - label.intrinsicContentSize.height) / 2, width: width, height: label.intrinsicContentSize.height)
      badge.addSubview(label); pile.addSubview(badge)
    }
    pile.setAccessibilityElement(true); pile.setAccessibilityLabel("Drag all \(current.count) items")
  }
  @objc private func visibleAreaChanged() { if !updatingViews { updateThumbnails() } }
  /// Applies icons and requests thumbnails only when the visible items, their views, or the display
  /// scale change. Scrolling within the same rows and status/selection renders do no work here.
  private func updateThumbnails() {
    guard !updatingViews, let window else { return }
    let current = items
    let visibleIDs: Set<UUID>
    if displayedExpanded {
      let viewport = scrollView.documentVisibleRect.insetBy(dx: 0, dy: -117)
      visibleIDs = Set(tiles.values.filter { $0.frame.intersects(viewport) }.flatMap(\.ids))
    } else { visibleIDs = Set(current.suffix(3).map(\.id)) }
    let scale = window.backingScaleFactor
    guard visibleIDs != thumbnailVisible || scale != thumbnailScale else { return }
    thumbnailVisible = visibleIDs; thumbnailScale = scale; thumbnailPasses += 1
    var keys: [ShelfThumbnailCache.Key] = [], unresolved: [ShelfItem] = []
    for item in current where visibleIDs.contains(item.id) && item.url != nil {
      guard let url = knownURL(item) else { unresolved.append(item); continue }
      if iconLoaded.insert(item.id).inserted {
        let icon = presentation.icons[item.id] ?? NSWorkspace.shared.icon(forFile: url.path)
        presentation.icons[item.id] = icon
        tileImages[item.id]?.image = icon; stackImages[item.id]?.image = icon
      }
      keys.append(.init(id: item.id, url: url, scale: scale))
    }
    if !unresolved.isEmpty { resolveURLs(unresolved) }
    presentation.thumbnails.update(keys, for: self) { [weak self] key, image in self?.applyThumbnail(image, to: key.id) }
  }
  /// Owned files need no resolution; bookmarked references wait for `resolveURLs`.
  private func knownURL(_ item: ShelfItem) -> URL? {
    if let url = presentation.resolvedURLs[item.id] { return url }
    guard item.bookmark == nil, let url = item.url else { return nil }
    presentation.resolvedURLs[item.id] = url
    return url
  }
  /// Bookmark resolution touches the file system and can stall on slow volumes, so it runs off the
  /// main thread once per item for all display copies; they refresh when it finishes.
  private func resolveURLs(_ pending: [ShelfItem]) {
    let presentation = self.presentation, shelfID = id
    let work = pending.filter { presentation.resolving.insert($0.id).inserted }
    guard !work.isEmpty else { return }
    Task { [weak app = self.app] in
      let resolved = await Task.detached(priority: .userInitiated) { work.map { ($0.id, $0.resolvedURL() ?? $0.url) } }.value
      for (itemID, url) in resolved where presentation.resolving.remove(itemID) != nil { presentation.resolvedURLs[itemID] = url }
      for controller in app?.shelfControllers(shelfID) ?? [] { controller.thumbnailVisible = nil; controller.updateThumbnails() }
    }
  }
  private func applyThumbnail(_ image: NSImage, to id: UUID) {
    if let view = tileImages[id], view.image !== image { view.image = image }
    tiles[id]?.preview = image
    if let view = stackImages[id] {
      let rounded: NSImage
      if let cached = presentation.rounded[id], cached.source === image { rounded = cached.image }
      else { rounded = Self.rounded(image); presentation.rounded[id] = (image, rounded) }
      if view.image !== rounded { view.image = rounded }
    }
    if stackIDs.last == id { pile.preview = image }
  }
  func updateStatus() {
    let count = items.count
    let status: String
    if pendingImages > 0 { status = message ?? "Adding \(pendingImages) item\(pendingImages == 1 ? "" : "s")…" }
    else if let message { status = message }
    else if count == 0 { status = "⌘V Paste · + Add files" }
    else { status = "\(count) item\(count == 1 ? "" : "s")" + (selected.isEmpty ? " · Drag to any app" : " · \(selected.count) selected") }
    summaryLabel.stringValue = status; summaryLabel.toolTip = status
    emptyLabel.stringValue = pendingImages > 0 ? "Receiving your drop…" : "Drop files, text, links, or images"
    if pendingImages > 0 { progress.startAnimation(nil) } else { progress.stopAnimation(nil) }
    for key in ["preview", "share", "copy"] { controls[key]?.isEnabled = count > 0 }
  }
  private func updateSelection() {
    for (id, tile) in tiles {
      let isSelected = selected.contains(id)
      tile.layer?.backgroundColor = isSelected ? NSColor.selectedContentBackgroundColor.cgColor : nil
      for case let label as NSTextField in tile.subviews {
        label.textColor = isSelected ? .alternateSelectedControlTextColor : (label.identifier?.rawValue == "subtitle" ? .secondaryLabelColor : .labelColor)
      }
      tile.setAccessibilitySelected(isSelected)
    }
  }
  /// Metadata edits (name, color, pin). Item removal goes through `remove(_:)` so it stays undoable.
  func change(_ body: @escaping (inout Shelf) throws -> Void) {
    let shelfID = id
    Task {
      do {
        try await app.withStore { try $0.update(shelfID, body) }
        app.refreshShelf(shelfID, message: app.imports.message(for: shelfID)); app.updateMenu()
      } catch { app.refreshShelf(shelfID, message: error.localizedDescription) }
    }
  }
  func select(_ id: UUID, extend: Bool) {
    if extend { if selected.contains(id) { selected.remove(id) } else { selected.insert(id) } }
    else { selected = [id] }
    message = nil
    // Selection is shared, while each display keeps its own scroll position.
    for controller in app.shelfControllers(self.id) { controller.updateSelection(); controller.updateStatus() }
  }
  /// Accepted work belongs to the app, including after this window closes.
  var pendingImages: Int { app.imports.pendingCount(for: id) }
  @discardableResult func ingest(_ board: NSPasteboard, preferFileReferences: Bool = false) -> Bool {
    do {
      let entries = try ShelfIngest.entries(from: board, preferFileReferences: preferFileReferences)
      try app.imports.accept(entries: entries, to: id)
      return true
    } catch { app.refreshShelf(id, message: error.localizedDescription); return false }
  }
  func writer(_ item: ShelfItem) -> NSPasteboardWriting? {
    if let url = item.resolvedURL() {
      guard FileManager.default.fileExists(atPath: url.path) else { app.refreshShelf(id, message: "A file was moved or removed."); return nil }
      // Saved images carry their pixels too, so apps that only accept image data still work.
      if let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .image) {
        let paste = NSPasteboardItem()
        paste.setString(url.absoluteString, forType: .fileURL)
        paste.setDataProvider(ShelfImagePasteboardProvider(url: url), forTypes: [NSPasteboard.PasteboardType(type.identifier)])
        return paste
      }
      return url as NSURL
    }
    let paste = NSPasteboardItem()
    paste.setString(item.value, forType: .string)
    if item.kind == .link { paste.setString(item.value.trimmingCharacters(in: .whitespacesAndNewlines), forType: .URL) }
    return paste
  }
  func copyItems(to board: NSPasteboard = .general) {
    let items = chosen
    var files: [URL] = []
    let values = items.compactMap { item -> NSPasteboardWriting? in
      guard let value = writer(item) else { return nil }
      if let url = item.url { files.append(url) }
      return value
    }
    guard !values.isEmpty else { updateStatus(); return }
    board.clearContents()
    if board.writeObjects(values) {
      app.rememberClipboardCopy(files, on: board)
      message = "Copied \(values.count) items" + (values.count < items.count ? "; \(items.count - values.count) unavailable." : "")
    }
    else { message = "The items could not be copied. Try again." }
    app.refreshShelf(id, message: message)
  }
  func addFiles() {
    guard let window else { return }
    prepareForDialog()
    let picker = NSOpenPanel(); picker.allowsMultipleSelection = true; picker.canChooseDirectories = true
    picker.beginSheetModal(for: window) { [weak self] response in
      guard let self else { return }
      defer { self.app.synchronizeDisplays() }
      guard response == .OK else { return }
      do { try self.app.imports.accept(entries: picker.urls.map { ShelfIngest.Entry(file: $0) }, to: self.id) }
      catch { self.app.refreshShelf(self.id, message: error.localizedDescription) }
    }
  }
  func preparePreviewURLs() throws -> [URL] {
    if previewDirectory == nil {
      let directory = FileManager.default.temporaryDirectory.appendingPathComponent("drop-shelf-preview-\(UUID().uuidString)")
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
      previewDirectory = directory
    }
    let directory = previewDirectory!
    let urls = try chosen.map { item -> URL in
      if let url = item.resolvedURL() {
        guard FileManager.default.fileExists(atPath: url.path) else { throw ShelfError("A preview file is no longer available.") }
        return url
      }
      let url = directory.appendingPathComponent(item.id.uuidString).appendingPathExtension(item.kind == .link ? "webloc" : "txt")
      if !FileManager.default.fileExists(atPath: url.path) {
        let data = item.kind == .link
          ? try PropertyListSerialization.data(fromPropertyList: ["URL": item.value.trimmingCharacters(in: .whitespacesAndNewlines)], format: .xml, options: 0)
          : Data(item.value.utf8)
        try data.write(to: url, options: .withoutOverwriting)
      }
      return url
    }
    let retained = Set(urls.map { $0.standardizedFileURL.path })
    for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) where !retained.contains(file.standardizedFileURL.path) {
      try FileManager.default.removeItem(at: file)
    }
    return urls
  }
  func closePreview() {
    if QLPreviewPanel.sharedPreviewPanelExists(), let panel = QLPreviewPanel.shared(), panel.dataSource === self {
      panel.orderOut(nil); panel.dataSource = nil; panel.delegate = nil
    }
    if let previewDirectory { try? FileManager.default.removeItem(at: previewDirectory) }
    previewDirectory = nil; previewURLs = []
  }
  func quickLook() {
    guard !chosen.isEmpty else { return }
    do {
      previewURLs = try preparePreviewURLs()
      guard let panel = QLPreviewPanel.shared() else { return }
      prepareForDialog()
      panel.dataSource = self; panel.delegate = self; panel.reloadData(); panel.makeKeyAndOrderFront(nil)
    } catch { app.report(error) }
  }
  func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { previewURLs.count }
  func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! { previewURLs[index] as NSURL }
  func share() {
    guard !chosen.isEmpty, let view = window?.contentView else { return }
    let values: [Any] = chosen.map { item in item.resolvedURL() as Any? ?? (item.kind == .link ? URL(string: item.value.trimmingCharacters(in: .whitespacesAndNewlines)) as Any? : nil) ?? item.value }
    sharePicker = NSSharingServicePicker(items: values)
    sharePicker?.show(relativeTo: NSRect(x: view.bounds.width - 80, y: 10, width: 24, height: 24), of: view, preferredEdge: .minY)
  }
  func closeShelf() {
    let shelfID = id
    guard !app.shelfControllers(id).contains(where: { $0.window?.attachedSheet != nil }) else {
      app.refreshShelf(id, message: "Finish the open dialog before closing this shelf."); return
    }
    Task {
      do {
        try await app.withStore { try $0.close(shelfID) }
        closePreview(); window?.orderOut(nil); app.updateMenu(); app.cleanAttachments()
      } catch { app.refreshShelf(shelfID, message: error.localizedDescription) }
    }
  }
  func actionMenu() -> NSMenu {
    let menu = NSMenu()
    func action(_ title: String, _ selector: Selector, enabled: Bool = true) {
      let item = NSMenuItem(title: title, action: selector, keyEquivalent: ""); item.target = self; item.isEnabled = enabled; menu.addItem(item)
    }
    menu.autoenablesItems = false
    action("Quick Look", #selector(previewAction), enabled: !chosen.isEmpty)
    action("Show in Finder", #selector(revealAction), enabled: chosen.contains { $0.url != nil })
    action("Copy Items", #selector(copyAction), enabled: !chosen.isEmpty)
    action("Copy to Folder…", #selector(exportAction), enabled: !chosen.isEmpty && !app.busy)
    action("Create ZIP…", #selector(zipAction), enabled: !chosen.isEmpty && !app.busy)
    action("Share…", #selector(shareAction), enabled: !chosen.isEmpty)
    menu.addItem(.separator())
    action("Rename Shelf…", #selector(renameAction))
    action("Change Color", #selector(colorAction))
    action("Move Selection to New Shelf", #selector(splitAction), enabled: !selectedItems.isEmpty)
    action("Remove from Shelf", #selector(removeAction), enabled: !selectedItems.isEmpty)
    if app.lastRemoval?.shelfID == id { action("Undo Remove", #selector(undoAction), enabled: app.lastRemoval?.restoring == false) }
    if app.busy { action("Cancel Export", #selector(cancelExportAction)) }
    menu.addItem(.separator())
    action("New Shelf", #selector(newAction))
    action("Settings…", #selector(settingsAction))
    return menu
  }
  @objc func previewAction() { quickLook() }
  @objc func copyAction() { copyItems() }
  @objc func shareAction() { share() }
  @objc func revealAction() { NSWorkspace.shared.activateFileViewerSelecting(chosen.compactMap { $0.resolvedURL() }) }
  @objc func colorAction() { change { $0.color = ($0.color + 1) % 5 } }
  @objc func newAction() { app.newShelf() }
  @objc func settingsAction() { app.showSettings() }
  @objc func undoAction() { undoRemoval() }
  @objc func cancelExportAction() { app.cancelExport() }
  @objc func renameAction() {
    guard let window else { return }
    prepareForDialog()
    let alert = NSAlert(); alert.messageText = "Name this shelf"
    let field = NSTextField(string: shelf?.name ?? "Shelf"); field.frame = NSRect(x: 0, y: 0, width: 240, height: 24)
    alert.accessoryView = field; alert.addButton(withTitle: "Save"); alert.addButton(withTitle: "Cancel")
    alert.beginSheetModal(for: window) { [weak self] response in
      defer { self?.app.synchronizeDisplays() }
      if response == .alertFirstButtonReturn { self?.change { $0.name = String(field.stringValue.prefix(80)) } }
    }
  }
  /// Delete and "Remove from Shelf": only an explicit selection is removed. With nothing selected
  /// this is a no-op with a hint; removing every item of a shelf asks first.
  @objc func removeAction() {
    let removing = selectedItems
    guard !removing.isEmpty else {
      app.refreshShelf(id, message: items.isEmpty ? nil : "Select items to remove · ⌘A selects all"); return
    }
    guard removing.count == items.count && removing.count > 1 else { remove(removing); return }
    app.confirm("Remove all \(removing.count) items from this shelf?",
      detail: "Original files are not deleted. You can undo with ⌘Z for a few seconds.", action: "Remove All", for: window) { [weak self] confirmed in
      if confirmed { self?.remove(removing) }
    }
  }
  /// Removes items and opens a short undo window; saved files stay on disk until it closes.
  func remove(_ removing: [ShelfItem]) {
    let ids = Set(removing.map(\.id)), shelfID = id
    let entries = items.enumerated().filter { ids.contains($0.element.id) }.map { (offset: $0.offset, item: $0.element) }
    guard !entries.isEmpty else { return }
    let removal = ShelfRemoval(shelfID: shelfID, entries: entries)
    app.beginRemoval(removal)
    Task {
      do {
        try await app.withStore { try $0.update(shelfID) { $0.items.removeAll { ids.contains($0.id) } } }
        selected.subtract(ids)
        app.refreshShelf(shelfID, message: app.lastRemoval === removal ? removal.hint : app.imports.message(for: shelfID)); app.updateMenu()
      } catch {
        app.endRemoval(removal)
        app.refreshShelf(shelfID, message: error.localizedDescription)
      }
    }
  }
  /// ⌘Z: puts the last removal from this shelf back in place while its undo window is open.
  @discardableResult func undoRemoval() -> Bool {
    guard let removal = app.lastRemoval, removal.shelfID == id, !removal.restoring else { return false }
    removal.restoring = true
    let shelfID = id, entries = removal.entries
    Task {
      do {
        let restored = try await app.withStore { store -> Int in
          var count = 0
          try store.update(shelfID) { shelf in
            for (offset, item) in entries where !shelf.items.contains(where: { $0.id == item.id || ($0.kind == item.kind && $0.value == item.value) }) {
              guard shelf.items.count < ShelfStore.maxItems else { break }
              shelf.items.insert(item, at: min(offset, shelf.items.count)); count += 1
            }
          }
          return count
        }
        app.endRemoval(removal)
        selected = Set(entries.map(\.item.id)).intersection(items.map(\.id))
        app.refreshShelf(shelfID, message: restored == entries.count ? "Restored \(restored) item\(restored == 1 ? "" : "s")"
          : "Restored \(restored) of \(entries.count) items; the rest are already here or the shelf is full.")
        app.updateMenu()
      } catch {
        removal.restoring = false
        app.refreshShelf(shelfID, message: error.localizedDescription)
      }
    }
    return true
  }
  @objc func splitAction() {
    let ids = Set(selectedItems.map(\.id)), shelfID = id
    Task {
      do {
        let new = try await app.withStore { try $0.split(ids, from: shelfID) }
        app.renderShelf(shelfID); await app.open(new)
      } catch { app.refreshShelf(shelfID, message: error.localizedDescription) }
    }
  }
  @objc func exportAction() { export(zip: false) }
  @objc func zipAction() { export(zip: true) }
  func export(zip: Bool) {
    guard !chosen.isEmpty, !app.busy, let window else { return }
    prepareForDialog()
    let picker = NSOpenPanel(); picker.canChooseFiles = false; picker.canChooseDirectories = true
    picker.prompt = zip ? "Save ZIP Here" : "Copy Here"
    picker.beginSheetModal(for: window) { [weak self] response in
      defer { self?.app.synchronizeDisplays() }
      guard let self, response == .OK, let folder = picker.url else { return }
      self.app.export(self.chosen, to: folder, zip: zip, controller: self)
    }
  }
}
