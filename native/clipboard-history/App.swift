import AppKit
import ApplicationServices
import Carbon
import CryptoKit

@MainActor final class ClipButton: NSButton {
  var handler: () -> Void
  init(_ title: String, _ handler: @escaping () -> Void) {
    self.handler = handler
    super.init(frame: .zero)
    self.title = title
    bezelStyle = .rounded
    target = self
    action = #selector(invoke)
  }
  required init?(coder: NSCoder) { fatalError() }
  @objc func invoke() { handler() }
}
@MainActor func clipLabel(_ text: String) -> NSTextField {
  NSTextField(wrappingLabelWithString: text)
}
@MainActor func clipRow(_ views: [NSView]) -> NSStackView {
  let stack = NSStackView(views: views)
  stack.orientation = .horizontal
  stack.spacing = 8
  return stack
}
@MainActor final class ClipBackground: NSView {
  override var isOpaque: Bool { true }
  override func draw(_ dirtyRect: NSRect) {
    NSColor.windowBackgroundColor.setFill()
    bounds.fill()
  }
  override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
}
@MainActor func clipColumn(_ views: [NSView], in view: NSView) {
  let background = ClipBackground(frame: view.bounds)
  background.autoresizingMask = [.width, .height]
  view.addSubview(background, positioned: .below, relativeTo: nil)
  let stack = NSStackView(views: views)
  stack.orientation = .vertical
  stack.spacing = 10
  stack.alignment = .leading
  stack.translatesAutoresizingMaskIntoConstraints = false
  view.addSubview(stack)
  NSLayoutConstraint.activate([
    stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
    stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
    stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 16),
    stack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -16),
  ])
  for child in views { child.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
}

@MainActor final class ClipboardBezelPanel: NSPanel {
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }
}

// Background alpha is separate from window alpha so text stays crisp and opaque.
@MainActor final class ClipboardBezelBackground: NSView {
  var radius: CGFloat = 25
  var opacity: CGFloat = 0.78
  override var isOpaque: Bool { false }
  override func draw(_ dirtyRect: NSRect) {
    let alpha: CGFloat = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency ? 1 : opacity
    NSColor(calibratedWhite: 0.1, alpha: alpha).setFill()
    NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
  }
}

// Flycut-style bezel: one translucent rounded panel with a source header, the clip text, and a
// position counter. Hold the hotkey modifiers and tap the key (or arrows) to cycle; release pastes.
@MainActor final class ClipboardPopup: NSWindowController, NSTextFieldDelegate, NSWindowDelegate {
  unowned let app: ClipboardApp
  let search = NSTextField(), preview = NSTextView(), status = NSTextField(labelWithString: "")
  let source = NSTextField(labelWithString: ""), date = NSTextField(labelWithString: "")
  let icon = NSImageView(), counter = NSTextField(labelWithString: "Empty")
  // Favorites filter state; toggled from the menu bar or ⌘S, not drawn as a control.
  let favoriteOnly = NSButton(checkboxWithTitle: "Favorites", target: nil, action: nil)
  var results: [Clip] = []
  var selection = 0
  var filterWork: DispatchWorkItem?
  /// True while the hotkey modifiers are still held from the press that opened the bezel.
  var holding = false
  var modifierFlagsProvider: () -> NSEvent.ModifierFlags = { NSEvent.modifierFlags }
  private let pasteHandler: (Clip) -> Void
  private var releasePoll: Timer?
  private var pendingShortcutRelease = false
  private var deliveryRequested = false
  private var dismissing = false
  private var presentationID = UUID()
  init(app: ClipboardApp, pasteHandler: ((Clip) -> Void)? = nil) {
    self.app = app
    self.pasteHandler = pasteHandler ?? { [unowned app] in app.deliver($0, paste: true) }
    let size = CGSize(width: 540, height: 340)
    let panel = ClipboardBezelPanel(
      contentRect: CGRect(origin: .zero, size: size),
      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    panel.title = "Clipboard History"
    panel.hidesOnDeactivate = false
    panel.becomesKeyOnlyIfNeeded = false
    panel.isReleasedWhenClosed = false
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = true
    panel.level = .floating
    panel.animationBehavior = .none
    panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .transient]
    panel.appearance = NSAppearance(named: .darkAqua)
    let background = ClipboardBezelBackground(frame: CGRect(origin: .zero, size: size))
    panel.contentView = background
    super.init(window: panel)
    panel.delegate = self

    // Plain containers: one panel, no inner boxes.
    func inset(_ frame: NSRect) -> NSView {
      let view = NSView(frame: frame)
      background.addSubview(view)
      return view
    }
    icon.frame = NSRect(x: 22, y: 298, width: 28, height: 28)
    icon.imageScaling = .scaleProportionallyUpOrDown
    background.addSubview(icon)
    let header = inset(NSRect(x: 58, y: 298, width: 460, height: 28))
    source.frame = NSRect(x: 0, y: 5, width: 260, height: 18)
    date.frame = NSRect(x: 260, y: 5, width: 200, height: 18)
    date.alignment = .right
    for label in [source, date] {
      label.textColor = .white
      label.font = .systemFont(ofSize: 12, weight: .medium)
      label.lineBreakMode = .byTruncatingTail
      header.addSubview(label)
    }
    date.textColor = NSColor.white.withAlphaComponent(0.65)
    date.font = .systemFont(ofSize: 12)
    // Inline search: plain text in the header, no field bezel or focus ring.
    search.frame = NSRect(x: 0, y: 5, width: 460, height: 18)
    search.isBordered = false
    search.isBezeled = false
    search.drawsBackground = false
    search.focusRingType = .none
    search.textColor = .white
    search.font = .systemFont(ofSize: 12, weight: .medium)
    search.placeholderAttributedString = NSAttributedString(
      string: "Type to search text or source app",
      attributes: [.foregroundColor: NSColor.white.withAlphaComponent(0.45), .font: search.font!])
    search.cell?.usesSingleLineMode = true
    search.cell?.lineBreakMode = .byTruncatingHead
    search.delegate = self
    search.setAccessibilityLabel("Search clipboard history")
    search.isHidden = true
    header.addSubview(search)

    let rule = NSView(frame: NSRect(x: 22, y: 291, width: 496, height: 1))
    rule.wantsLayer = true
    rule.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.1).cgColor
    background.addSubview(rule)
    let body = inset(NSRect(x: 10, y: 42, width: 520, height: 244))
    preview.isEditable = false
    preview.isSelectable = false
    preview.font = .systemFont(ofSize: 15)
    preview.textColor = .white
    preview.drawsBackground = false
    preview.isRichText = false
    preview.textContainerInset = CGSize(width: 12, height: 12)
    preview.textContainer?.lineFragmentPadding = 0
    preview.setAccessibilityLabel("Selected clipboard text preview")
    let detail = NSScrollView(frame: body.bounds)
    detail.drawsBackground = false
    detail.borderType = .noBorder
    detail.hasVerticalScroller = false
    detail.hasHorizontalScroller = false
    detail.verticalScrollElasticity = .none
    detail.autoresizingMask = [.width, .height]
    preview.frame = detail.bounds
    preview.isVerticallyResizable = true
    preview.autoresizingMask = [.width]
    preview.textContainer?.widthTracksTextView = true
    detail.documentView = preview
    body.addSubview(detail)

    counter.frame = NSRect(x: 170, y: 12, width: 200, height: 20)
    counter.alignment = .center
    counter.textColor = .white
    counter.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
    counter.setAccessibilityLabel("Clipboard position")
    background.addSubview(counter)
    status.frame = NSRect(x: 22, y: 14, width: 150, height: 16)
    status.font = .systemFont(ofSize: 11)
    status.textColor = NSColor.white.withAlphaComponent(0.6)
    status.lineBreakMode = .byTruncatingTail
    background.addSubview(status)
  }
  required init?(coder: NSCoder) { fatalError() }
  deinit { releasePoll?.invalidate() }
  var selected: Clip? { results.indices.contains(selection) ? results[selection] : nil }
  var isShowing: Bool { window?.isVisible == true && !dismissing }
  func show(favorites: Bool = false, fromShortcut: Bool = false) {
    cancelShortcutInteraction()
    presentationID = UUID(); dismissing = false; deliveryRequested = false
    filterWork?.cancel()
    search.stringValue = ""
    search.isHidden = true
    source.isHidden = false; date.isHidden = false
    favoriteOnly.state = favorites ? .on : .off
    selection = 0
    results = []
    refresh()
    if let window {
      let screen =
        NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
      if let frame = screen?.visibleFrame {
        window.setFrameOrigin(
          NSPoint(
            x: frame.midX - window.frame.width / 2, y: frame.midY - window.frame.height / 2 + 40))
      } else {
        window.center()
      }
      // First frame at full opacity, no fade-in; a zero-length animation also replaces any
      // dismissal fade still running from the previous presentation.
      NSAnimationContext.runAnimationGroup { context in
        context.duration = 0
        window.animator().alphaValue = 1
      }
      showWindow(nil)
      window.makeKeyAndOrderFront(nil)
      window.makeFirstResponder(preview)
    }
    if fromShortcut { beginShortcutInteraction() }
  }
  /// Repeated hotkey presses while visible advance like Flycut.
  func advance() { move(1) }
  func beginShortcutInteraction() {
    guard isShowing else { return }
    cancelShortcutInteraction()
    holding = true; deliveryRequested = false
    // A very fast tap may release before the panel becomes key, so no local flagsChanged
    // event arrives. Sample now and poll only for the lifetime of this held shortcut.
    let timer = Timer(timeInterval: 0.02, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self else { return }
        self.modifiersChanged(self.modifierFlagsProvider())
      }
    }
    releasePoll = timer
    RunLoop.main.add(timer, forMode: .common)
    modifiersChanged(modifierFlagsProvider())
  }
  func cancelShortcutInteraction() {
    holding = false
    pendingShortcutRelease = false
    releasePoll?.invalidate(); releasePoll = nil
  }
  func modifiersChanged(_ flags: NSEvent.ModifierFlags) {
    guard holding else { return }
    guard isShowing else { cancelShortcutInteraction(); return }
    if flags.intersection([.command, .option, .control]).isEmpty {
      cancelShortcutInteraction()
      if app.ready { pasteSelection() }
      else { pendingShortcutRelease = true }
    }
  }
  func dismiss() {
    cancelShortcutInteraction()
    guard let window, window.isVisible else { return }
    dismissing = true
    let closingPresentation = presentationID
    NSAnimationContext.runAnimationGroup({ context in
      context.duration = 0.1
      window.animator().alphaValue = 0
    }, completionHandler: { [weak self, weak window] in
      MainActor.assumeIsolated {
        guard self?.presentationID == closingPresentation else { return }
        window?.orderOut(nil)
        window?.alphaValue = 1
      }
    })
  }
  @objc func filterFavorites() { refresh() }
  func toggleFavoritesFilter() {
    favoriteOnly.state = favoriteOnly.state == .on ? .off : .on
    refresh()
  }
  func beginSearch(_ initial: String = "") {
    cancelShortcutInteraction()
    search.isHidden = false
    source.isHidden = true
    date.isHidden = true
    window?.makeFirstResponder(search)
    if !initial.isEmpty {
      search.stringValue += initial
      search.currentEditor()?.selectedRange = NSRange(location: search.stringValue.utf16.count, length: 0)
      refresh()
    }
  }
  func endSearch() {
    search.stringValue = ""
    search.isHidden = true
    source.isHidden = false
    date.isHidden = false
    window?.makeFirstResponder(preview)
    refresh()
  }
  func refresh() {
    let id = selected?.id
    results = app.clips.filter {
      (favoriteOnly.state == .off || $0.favorite)
        && ClipboardPolicy.matches($0, query: search.stringValue)
    }
    selection = id.flatMap { id in results.firstIndex { $0.id == id } } ?? 0
    updatePreview()
    if pendingShortcutRelease, app.ready {
      pendingShortcutRelease = false
      pasteSelection()
    }
  }
  func controlTextDidChange(_ obj: Notification) {
    filterWork?.cancel()
    let work = DispatchWorkItem { [weak self] in self?.refresh() }
    filterWork = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.06, execute: work)
  }
  func updatePreview() {
    let unavailable = app.storeProblem.map {
      "History is unavailable: \($0) Use Retry or Reset History in the Clipboard History menu."
    }
    preview.string = selected.map { String($0.text.prefix(16_384)) }
      ?? (!search.stringValue.isEmpty ? "No matching clips. Try a shorter search or another source app." : favoriteOnly.state == .on ? "No favorites yet. Press ⌘D on a clip to keep it here." : unavailable ?? (app.paused ? "History is paused. Resume from the Clipboard History menu to collect new clips." : "Copy text to begin. Your history stays on this Mac."))
    preview.textColor = selected == nil ? NSColor.white.withAlphaComponent(0.6) : .white
    preview.scrollToBeginningOfDocument(nil)
    let origin = selected.map { sourceInfo($0.source) }
    icon.image = origin?.icon
      ?? NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: "Clipboard")
    icon.contentTintColor = .white
    source.stringValue = selected.map {
      ($0.favorite ? "★ " : "") + (origin?.name ?? ($0.source.isEmpty ? "Unknown source" : $0.source))
    } ?? "Clipboard History"
    date.stringValue = selected?.copied.formatted(date: .abbreviated, time: .shortened) ?? ""
    counter.stringValue = results.isEmpty ? "Empty" : "\(selection + 1) of \(results.count)"
    let note = app.storeProblem.map { _ in "History unavailable" } ?? app.problem ?? app.shortcutProblem
    status.stringValue = note
      ?? (app.paused ? "Paused" : favoriteOnly.state == .on ? "★ Favorites" : "")
    status.toolTip = app.storeProblem ?? note
    status.textColor = note == nil ? NSColor.white.withAlphaComponent(0.6) : .systemOrange
    window?.contentView?.toolTip =
      "↑↓ browse · ↵ paste · type to search · ⌘D favorite · ⌘S favorites · ⌘⌫ delete · Esc close"
  }
  /// Source app name and icon, cached so browsing never waits on LaunchServices or disk.
  var sources: [String: (name: String?, icon: NSImage?)] = [:]
  func sourceInfo(_ bundle: String) -> (name: String?, icon: NSImage?) {
    if let cached = sources[bundle] { return cached }
    let url = bundle.isEmpty ? nil : NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle)
    let info = (
      url?.deletingPathExtension().lastPathComponent,
      url.map { Self.rasterized(NSWorkspace.shared.icon(forFile: $0.path)) }
    )
    sources[bundle] = info
    return info
  }
  /// Called when a clip is added, so the bezel's first frame never waits on LaunchServices.
  func warmSource(_ bundle: String) { _ = sourceInfo(bundle) }
  /// Draws an app icon once at the bezel's 28 pt size; later frames only composite the bitmap.
  static func rasterized(_ image: NSImage) -> NSImage {
    let size = NSSize(width: 28, height: 28)
    let pixels = Int(28 * (NSScreen.screens.map(\.backingScaleFactor).max() ?? 2))
    guard
      let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0),
      let context = NSGraphicsContext(bitmapImageRep: rep)
    else { return image }
    rep.size = size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    image.draw(in: NSRect(origin: .zero, size: size))
    NSGraphicsContext.restoreGraphicsState()
    let rendered = NSImage(size: size)
    rendered.addRepresentation(rep)
    return rendered
  }
  @objc func pasteSelection() {
    cancelShortcutInteraction()
    guard isShowing, !deliveryRequested, let selected else { return }
    deliveryRequested = true
    pasteHandler(selected)
  }
  func copySelection() {
    cancelShortcutInteraction()
    guard isShowing, !deliveryRequested, let selected else { return }
    deliveryRequested = true
    app.deliver(selected, paste: false)
  }
  func toggleFavorite() { if let selected { app.mutate { try $0.favorite(selected.id) } } }
  func deleteSelection() { if let selected { app.mutate { try $0.delete(selected.id) } } }
  func move(_ delta: Int) {
    guard !results.isEmpty else { return }
    // Wrap around like Flycut so cycling never dead-ends.
    selection = (selection + delta + results.count) % results.count
    updatePreview()
  }
  func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
    switch commandSelector {
    case #selector(NSResponder.moveDown(_:)): move(1)
    case #selector(NSResponder.moveUp(_:)): move(-1)
    case #selector(NSResponder.insertNewline(_:)): pasteSelection()
    case #selector(NSResponder.cancelOperation(_:)):
      if search.stringValue.isEmpty { dismiss() } else { endSearch() }
    case #selector(NSResponder.deleteBackward(_:)) where search.stringValue.isEmpty: endSearch()
    default: return false
    }
    return true
  }
  func windowDidResignKey(_ notification: Notification) {
    cancelShortcutInteraction()
    dismissing = true
    window?.orderOut(nil)
  }
}

@MainActor final class ClipboardApp: NSObject, NSApplicationDelegate, NSMenuDelegate {
  static let shared = ClipboardApp()
  static let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
    "Library/Application Support/Productivity OS/Clipboard History")
  let worker = ClipWorker()
  var defaults = UserDefaults.standard
  /// Overridable so QA never touches real history or the Keychain (a key skips the Keychain).
  var storeURL = ClipboardApp.root.appendingPathComponent("history.sqlite")
  var storeKey: SymmetricKey?
  /// Set for the running helper: enables the clipboard timer and automatic storage retries.
  var launched = false
  var suspensionReasons = Set<String>()
  var clips: [Clip] = []
  var ready = false, suspended = false, problem: String?
  /// Why saved history can't be opened, and whether Reset History can fix it.
  var storeProblem: String?, storeResettable = false
  var storeOpening = false, storeFailures = 0, storeAttempts = 0
  /// Uptime before which a copy does not retry storage again (backoff after failures).
  var nextStoreRetry: TimeInterval = 0
  var storeRetryTimer: Timer?
  private var pendingCopy: (change: Int, time: TimeInterval)?
  /// Counts clip changes the UI has applied (QA observes refresh work through it).
  var clipChanges = 0
  var askedAccessibility = false
  var shortcutProblem: String?
  var pendingWrites = 0, shutdownRequested = false
  var board = NSPasteboard.general
  var lastChange = 0
  var timer: Timer?, expiryTimer: Timer?, statusItem: NSStatusItem?, hotkey: EventHotKeyRef?,
    hotkeyHandler: EventHandlerRef?, monitor: Any?
  var lastExternal: NSRunningApplication?, destination: NSRunningApplication?
  private var pasteGeneration = UUID()
  private var pendingPaste: Task<Void, Never>?
  var popup: ClipboardPopup?, settings: NSWindow?
  /// `quit-if-idle` arrived before launch finished. `terminate` is replaceable for QA.
  var quitAtLaunch = false
  var terminate: () -> Void = { NSApp.terminate(nil) }
  /// Nothing on screen and no paste pending, so quitting loses nothing (`quit-if-idle`). Background
  /// writes don't count: termination already waits for them.
  var isIdle: Bool {
    popup?.window?.isVisible != true && settings?.isVisible != true && NSApp.modalWindow == nil
      && !NSApp.windows.contains { $0.isVisible && ($0.isSheet || $0.attachedSheet != nil) }
      && pendingPaste == nil
  }
  var recordingShortcut = false
  var keyButton: NSButton?, pausedButton: NSButton?, loginButton: NSButton?, exclusions: NSTextView?
  var observers: [NSObjectProtocol] = []
  var received = false
  var paused: Bool { defaults.bool(forKey: "paused") }
  var excluded: Set<String> { Set(defaults.stringArray(forKey: "excluded") ?? []) }
  var loginPlist: URL {
    FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
      "Library/LaunchAgents/com.productivity-os.clipboard-history.plist")
  }
  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.accessory)
    let others = NSRunningApplication.runningApplications(
      withBundleIdentifier: "com.productivity-os.clipboard-history"
    ).filter { $0.processIdentifier != getpid() }
    if !others.isEmpty || quitAtLaunch {
      NSApp.terminate(nil)
      return
    }
    if defaults.object(forKey: "excluded") == nil {
      let known = [
        "com.1password.1password", "com.agilebits.onepassword7", "com.bitwarden.desktop",
        "com.apple.Passwords", "org.keepassxc.keepassxc", "com.dashlane.Dashlane",
        "in.sinew.Enpass-Desktop",
      ]
      defaults.set(
        known.filter { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil },
        forKey: "excluded")
    }
    lastExternal = validDestination(NSWorkspace.shared.frontmostApplication)
    lastChange = board.changeCount
    launched = true
    makeMenu()
    observe()
    registerShortcut()
    installKeys()
    updatePolling()
    Task {
      await openStore()
      // Build the bezel now so the first ⌘⇧V only has to show it.
      preparePopup()
      if !CommandLine.arguments.contains("--background") && !received { showHistory() }
    }
    NSApp.mainMenu = NSMenu()
    let root = NSMenuItem()
    let menu = NSMenu()
    root.submenu = menu
    NSApp.mainMenu?.addItem(root)
    menu.addItem(withTitle: "Quit Clipboard History", action: #selector(quit), keyEquivalent: "q")
      .target = self
    let editRoot = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
    let editMenu = NSMenu(title: "Edit")
    editRoot.submenu = editMenu
    editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
    editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
    editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
    editMenu.addItem(
      withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
    NSApp.mainMenu?.addItem(editRoot)
  }
  func application(_ application: NSApplication, open urls: [URL]) {
    for url in urls {
      guard let c = URLComponents(url: url, resolvingAgainstBaseURL: false),
        c.scheme == "pos-clipboard", c.path.isEmpty, c.query == nil, c.fragment == nil,
        c.user == nil, c.password == nil, c.port == nil
      else { continue }
      switch c.host {
      case "history":
        received = true
        showHistory()
      case "settings":
        received = true
        showSettings()
      case "quit-if-idle":
        // Sent by the installer with `open -g`. Never activates or shows anything; exits 0 only when idle.
        received = true
        if !launched {
          // Launched just to receive this: quit before the menu bar item or any window exists.
          quitAtLaunch = true
        } else {
          DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
              guard let self, self.isIdle else { return }
              self.terminate()
            }
          }
        }
      default: break
      }
    }
  }
  /// Opens saved history. Launch and Retry may show a Keychain prompt; automatic retries never do.
  func openStore(interactive: Bool = true) async {
    guard !ready, !storeOpening, !shutdownRequested else { return }
    storeOpening = true
    storeAttempts += 1
    defer { storeOpening = false }
    do {
      let opened = try await worker.open(url: storeURL, key: storeKey, interactive: interactive)
      storeOpened(opened, skipped: await worker.skipped)
    } catch { storeFailed(error) }
  }
  private func storeOpened(_ opened: [Clip], skipped: Int) {
    clips = opened
    ready = true
    storeProblem = nil
    storeResettable = false
    storeFailures = 0
    storeRetryTimer?.invalidate()
    storeRetryTimer = nil
    problem =
      skipped == 0
      ? nil
      : "Skipped \(skipped) damaged \(skipped == 1 ? "entry" : "entries"); the rest of history is intact."
    clipsChanged()
    // The copy that prompted a retry is kept only if storage opened at once: exclusions and the
    // source are judged by the app in front now, which must still be the app that copied.
    if let pending = pendingCopy, ProcessInfo.processInfo.systemUptime - pending.time < 1.5,
      board.changeCount == pending.change, !paused, !suspended
    {
      capture(pending.change)
    }
    pendingCopy = nil
    updateMenu()
  }
  private func storeFailed(_ error: Error) {
    ready = false
    pendingCopy = nil
    storeProblem = error.localizedDescription
    storeResettable = (error as? ClipError)?.resettable ?? false
    storeFailures += 1
    // Copies retry after 5 s, 15 s, 45 s… (at most every 5 min); unlock, wake and Retry don't wait.
    let delay = min(300, 5 * pow(3, Double(storeFailures - 1)))
    nextStoreRetry = ProcessInfo.processInfo.systemUptime + delay
    storeRetryTimer?.invalidate()
    storeRetryTimer = nil
    // The first few retries also run on their own, for problems that clear shortly after login.
    if launched && storeFailures <= 3 {
      let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
        MainActor.assumeIsolated { self?.retryStore(.timer) }
      }
      timer.tolerance = delay / 10
      RunLoop.main.add(timer, forMode: .common)
      storeRetryTimer = timer
    }
    if popup?.isShowing == true { popup?.updatePreview() }
    updateMenu()
  }
  enum StoreRetry { case timer, copy, wake, manual }
  func retryStore(_ trigger: StoreRetry) {
    guard launched, !ready, !storeOpening, !shutdownRequested else { return }
    if trigger == .copy && ProcessInfo.processInfo.systemUptime < nextStoreRetry { return }
    Task { await openStore(interactive: trigger == .manual) }
  }
  @objc func retryStoreNow() { retryStore(.manual) }
  @objc func resetHistory() {
    guard !ready, storeResettable, !storeOpening else { return }
    let alert = NSAlert()
    alert.messageText = "Reset clipboard history?"
    alert.informativeText =
      "Clipboard History can't open its saved history. \(storeProblem ?? "") Reset moves the unreadable file aside in the Clipboard History folder and starts a new, empty history."
    alert.addButton(withTitle: "Reset History")
    alert.addButton(withTitle: "Cancel")
    guard alert.runModal() == .alertFirstButtonReturn else { return }
    Task { await resetStore() }
  }
  /// Moves unreadable history aside (never deleting it) and starts an empty one.
  func resetStore() async {
    guard !ready, !storeOpening, !shutdownRequested else { return }
    storeOpening = true
    defer { storeOpening = false }
    do {
      let reset = try await worker.reset(url: storeURL, key: storeKey)
      storeOpened(reset.clips, skipped: 0)
      problem = reset.movedTo.map { "Started a new history; the old file is \($0.lastPathComponent)." }
    } catch { storeFailed(error) }
  }
  func fail(_ error: Error) {
    problem = error.localizedDescription
    if popup?.isShowing == true { popup?.updatePreview() }
    updateMenu()
  }
  func mutate(
    _ action: @escaping (ClipStore) throws -> Void, added source: String? = nil,
    completion: (() -> Void)? = nil
  ) {
    guard !shutdownRequested else { return }
    pendingWrites += 1
    Task {
      defer {
        pendingWrites -= 1
        if shutdownRequested && pendingWrites == 0 {
          NSApp.reply(toApplicationShouldTerminate: true)
        }
      }
      do {
        let result = try await worker.run(action)
        problem = nil
        if result.changed {
          clips = result.clips
          clipsChanged()
        }
        // Resolve the source app's name and icon now, off the hotkey path.
        if let source { popup?.warmSource(source) }
        updateMenu()
      } catch { fail(error) }
      completion?()
    }
  }
  /// Clips changed: refresh only a visible bezel and re-arm expiry. The menu is built when opened.
  func clipsChanged() {
    clipChanges += 1
    if popup?.isShowing == true { popup?.refresh() }
    scheduleExpiry()
  }
  /// Expiry runs when the oldest ordinary clip reaches 7 days, not on a fixed interval.
  func scheduleExpiry() {
    expiryTimer?.invalidate()
    expiryTimer = nil
    guard ready, !shutdownRequested,
      let oldest = clips.lazy.filter({ !$0.favorite }).map(\.copied).min()
    else { return }
    let delay = max(1, oldest.addingTimeInterval(ClipLimits().age).timeIntervalSinceNow + 1)
    let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self else { return }
        self.expiryTimer = nil
        self.mutate({ try $0.expire() }, completion: { [weak self] in
          if self?.expiryTimer == nil { self?.scheduleExpiry() }
        })
      }
    }
    timer.tolerance = min(60, delay / 10)
    RunLoop.main.add(timer, forMode: .common)
    expiryTimer = timer
  }
  /// The clipboard check runs only while collection is possible. Resuming resyncs the change
  /// counter, so nothing copied while paused, locked or asleep is imported.
  func updatePolling() {
    let active = launched && !shutdownRequested && !paused && !suspended
    guard active != (timer != nil) else { return }
    if active {
      lastChange = board.changeCount
      // Common modes keep collecting while a menu or modal is open; the callback is already on main.
      let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
        MainActor.assumeIsolated { self?.poll() }
      }
      timer.tolerance = 0.25
      RunLoop.main.add(timer, forMode: .common)
      self.timer = timer
    } else {
      timer?.invalidate()
      timer = nil
    }
  }
  func poll() {
    guard !shutdownRequested else { return }
    guard !paused, !suspended else {
      lastChange = board.changeCount
      return
    }
    // The change counter is the only read per tick; everything else waits for a real change.
    let change = board.changeCount
    guard change != lastChange else { return }
    lastChange = change
    guard ready else {
      // A copy is a natural moment to retry storage; the copy itself is kept only if that works at once.
      pendingCopy = (change, ProcessInfo.processInfo.systemUptime)
      retryStore(.copy)
      return
    }
    capture(change)
  }
  func capture(_ change: Int) {
    if #available(macOS 15.4, *) {
      let access = board.accessBehavior
      if access == .alwaysDeny || access == .ask {
        let message =
          "Allow clipboard access for Clipboard History in System Settings, then copy again."
        if problem != message {
          problem = message
          updateMenu()
          if popup?.isShowing == true { popup?.updatePreview() }
        }
        return
      }
    }
    let foreground = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
    let types = (board.types ?? []).map(\.rawValue)
    // Check markers before requesting a text payload. Never request image or file data.
    guard Set(types).isDisjoint(with: ClipboardPolicy.ignored), !excluded.contains(foreground)
    else { return }
    let source =
      board.string(forType: NSPasteboard.PasteboardType("org.nspasteboard.source")) ?? foreground
    guard
      ClipboardPolicy.accepts(
        types: types, source: source, foreground: foreground, excluded: excluded),
      let text = readText(change: change)
    else { return }
    mutate({ try $0.add(text, source: source) }, added: source)
  }
  /// Reads copied text as UTF-8 bytes and rejects oversized copies before building a String from them.
  func readText(change: Int) -> String? {
    var text: String?
    if let data = board.data(forType: .string) {
      guard data.count <= ClipLimits().itemBytes else {
        fail(ClipError("Copy skipped: text exceeds the 1 MiB entry limit"))
        return nil
      }
      text = String(data: data, encoding: .utf8)
    }
    if text == nil { text = board.string(forType: .string) }
    guard let text, !text.isEmpty, board.changeCount == change else { return nil }
    return text
  }
  func observe() {
    let center = NSWorkspace.shared.notificationCenter
    observers.append(
      center.addObserver(
        forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
      ) { [weak self] note in
        MainActor.assumeIsolated {
          guard
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
            app.bundleIdentifier != "com.productivity-os.clipboard-history",
            app.bundleIdentifier != "com.raycast.macos"
          else { return }
          self?.lastExternal = app
        }
      })
    for name in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification]
    {
      observers.append(
        center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
          MainActor.assumeIsolated {
            self?.suspend(
              true, reason: name == NSWorkspace.willSleepNotification ? "sleep" : "session")
          }
        })
    }
    for name in [NSWorkspace.didWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
      observers.append(
        center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
          MainActor.assumeIsolated {
            self?.suspend(
              false, reason: name == NSWorkspace.didWakeNotification ? "sleep" : "session")
          }
        })
    }
    // Nobody copies onto a sleeping display: stop the clipboard check until it wakes.
    for (name, asleep) in [
      (NSWorkspace.screensDidSleepNotification, true), (NSWorkspace.screensDidWakeNotification, false),
    ] {
      observers.append(
        center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
          MainActor.assumeIsolated { self?.suspend(asleep, reason: "display") }
        })
    }
    observers.append(
      NotificationCenter.default.addObserver(
        forName: .NSSystemClockDidChange, object: nil, queue: .main
      ) { [weak self] _ in MainActor.assumeIsolated { self?.scheduleExpiry() } })
    let distributed = DistributedNotificationCenter.default()
    observers.append(
      distributed.addObserver(
        forName: NSNotification.Name("com.apple.screenIsLocked"), object: nil, queue: .main
      ) { [weak self] _ in MainActor.assumeIsolated { self?.suspend(true, reason: "lock") } })
    observers.append(
      distributed.addObserver(
        forName: NSNotification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main
      ) { [weak self] _ in MainActor.assumeIsolated { self?.suspend(false, reason: "lock") } })
  }
  func suspend(_ value: Bool, reason: String = "manual") {
    if value { invalidatePendingPaste() }
    if value { suspensionReasons.insert(reason) } else { suspensionReasons.remove(reason) }
    suspended = !suspensionReasons.isEmpty
    lastChange = board.changeCount
    if value {
      popup?.cancelShortcutInteraction()
      popup?.window?.orderOut(nil)
      popup?.preview.string = ""
    }
    updatePolling()
    guard !value else { return }
    // Unlock, wake and a returning session bring the Keychain and disk back: retry storage now,
    // and re-arm expiry, whose timer does not count time asleep.
    retryStore(.wake)
    scheduleExpiry()
  }
  /// Builds the bezel ahead of the first hotkey press and warms the newest clips' source icons.
  func preparePopup() {
    if popup == nil { popup = ClipboardPopup(app: self) }
    guard let popup, !popup.isShowing else { return }
    for source in Set(clips.prefix(20).map(\.source)) { popup.warmSource(source) }
    popup.refresh()
    popup.window?.contentView?.layoutSubtreeIfNeeded()
    popup.window?.displayIfNeeded()
  }
  func validDestination(_ app: NSRunningApplication?) -> NSRunningApplication? {
    guard let app, !app.isTerminated, app.processIdentifier != getpid(),
      app.bundleIdentifier != "com.raycast.macos"
    else { return nil }
    return app
  }
  @objc func showHistory() {
    openHistory(fromShortcut: false)
  }
  func showHistoryFromShortcut() {
    guard !recordingShortcut else { return }
    received = true
    openHistory(fromShortcut: true)
  }
  private func openHistory(fromShortcut: Bool) {
    invalidatePendingPaste()
    guard !suspended else { return }
    if fromShortcut, let popup, popup.isShowing, popup.window?.isKeyWindow == true {
      if popup.holding { popup.advance() }
      else { popup.beginShortcutInteraction() }
      return
    }
    destination =
      validDestination(NSWorkspace.shared.frontmostApplication) ?? validDestination(lastExternal)
    if popup == nil { popup = ClipboardPopup(app: self) }
    popup?.show(fromShortcut: fromShortcut)
  }
  func deliver(_ clip: Clip, paste: Bool) {
    invalidatePendingPaste()
    guard !suspended else { return }
    let item = NSPasteboardItem()
    item.setString(clip.text, forType: .string)
    item.setString(clip.source, forType: NSPasteboard.PasteboardType("org.nspasteboard.source"))
    item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.AutoGeneratedType"))
    board.clearContents()
    guard board.writeObjects([item]) else {
      fail(ClipError("Could not copy the selected entry"))
      return
    }
    lastChange = board.changeCount
    popup?.window?.orderOut(nil)
    guard paste else { return }
    guard AXIsProcessTrusted() else {
      // Ask macOS once per launch; afterwards stay quiet so pasting is never interrupted.
      if !askedAccessibility {
        askedAccessibility = true
        _ = AXIsProcessTrustedWithOptions(
          [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
      }
      quietNotice(
        "Copied. Press ⌘V to paste. Enable Accessibility for Clipboard History to paste automatically."
      )
      return
    }
    guard let target = validDestination(destination)
    else {
      quietNotice("Copied. The previous app is unavailable; paste manually with ⌘V.")
      return
    }
    let expectedChange = lastChange
    target.activate()
    schedulePaste(expectedChange: expectedChange, isDestinationReady: {
      NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier
    })
  }
  private func invalidatePendingPaste() {
    pasteGeneration = UUID()
    pendingPaste?.cancel(); pendingPaste = nil
  }
  /// The real delayed delivery loop, with injectable focus and event output for isolated QA.
  func schedulePaste(expectedChange: Int, isDestinationReady: @escaping () -> Bool,
    sendPaste: (() -> Void)? = nil) {
    invalidatePendingPaste()
    let generation = pasteGeneration
    pendingPaste = Task { [weak self] in
      guard let self else { return }
      defer { if pasteGeneration == generation { pendingPaste = nil } }
      for _ in 0..<10 {
        do { try await Task.sleep(nanoseconds: 30_000_000) } catch { return }
        guard pasteGeneration == generation, board.changeCount == expectedChange,
          !suspended, popup?.isShowing != true else { return }
        if isDestinationReady() {
          guard pasteGeneration == generation, popup?.isShowing != true else { return }
          if let sendPaste { sendPaste() } else { Self.sendPasteEvents() }
          return
        }
      }
      quietNotice("Copied. Could not restore the previous app; paste manually with ⌘V.")
    }
  }
  static func sendPasteEvents() {
    let source = CGEventSource(stateID: .combinedSessionState)
    let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true)
    let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false)
    down?.flags = .maskCommand
    up?.flags = .maskCommand
    down?.post(tap: .cghidEventTap)
    up?.post(tap: .cghidEventTap)
  }
  // Paste-path notices go to the menu-bar status line instead of a modal alert.
  func quietNotice(_ message: String) {
    problem = message
    updateMenu()
    NSSound.beep()
  }
  func showNotice(_ message: String) {
    problem = message
    let alert = NSAlert()
    alert.messageText = "Clipboard History"
    alert.informativeText = message
    alert.addButton(withTitle: "OK")
    alert.runModal()
  }
  func makeMenu() {
    statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    statusItem?.button?.image = NSImage(
      systemSymbolName: "clipboard", accessibilityDescription: "Clipboard History")
    let menu = NSMenu()
    menu.delegate = self
    statusItem?.menu = menu
    updateMenu()
  }
  /// The menu itself is filled only when it opens (`menuNeedsUpdate`); state changes just dim the icon.
  func updateMenu() {
    statusItem?.button?.appearsDisabled = paused || storeProblem != nil
  }
  func menuNeedsUpdate(_ menu: NSMenu) {
    menu.removeAllItems()
    fillMenu(menu)
  }
  func fillMenu(_ menu: NSMenu) {
    func add(_ title: String, _ action: Selector) {
      let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
      item.target = self
    }
    func note(_ title: String, detail: String? = nil) {
      let item = menu.addItem(withTitle: title, action: nil, keyEquivalent: "")
      item.isEnabled = false
      item.toolTip = detail
    }
    if let storeProblem {
      let reason = storeProblem.components(separatedBy: ". ").first ?? storeProblem
      note("History unavailable — " + reason.trimmingCharacters(in: CharacterSet(charactersIn: ".")), detail: storeProblem)
      add("Retry Opening History", #selector(retryStoreNow))
      if storeResettable { add("Reset History…", #selector(resetHistory)) }
      menu.addItem(.separator())
    } else if !ready {
      note("Opening history…")
    } else {
      note(problem ?? (paused ? "Collection paused" : "\(clips.count) entries · Local history"))
    }
    if let shortcutProblem {
      note(shortcutProblem)
      add("Change Shortcut…", #selector(showSettings))
    }
    add("Open Clipboard History", #selector(showHistory))
    add("Favorites", #selector(showFavorites))
    add(paused ? "Resume Collection" : "Pause Collection", #selector(togglePause))
    menu.addItem(.separator())
    add("Settings…", #selector(showSettings))
    add("Clear History…", #selector(clearHistory))
    add("Quit Clipboard History", #selector(quit))
  }
  @objc func showFavorites() {
    showHistory()
    popup?.cancelShortcutInteraction()
    popup?.favoriteOnly.state = .on
    popup?.refresh()
  }
  @objc func togglePause() {
    defaults.set(!paused, forKey: "paused")
    lastChange = board.changeCount
    pausedButton?.state = paused ? .on : .off
    popup?.updatePreview()
    updateMenu()
    updatePolling()
  }
  @objc func clearHistory() {
    let alert = NSAlert()
    alert.messageText = "Clear clipboard history?"
    alert.informativeText =
      "Ordinary entries will be deleted. The current system clipboard is unchanged."
    let favorites = NSButton(checkboxWithTitle: "Also delete favorites", target: nil, action: nil)
    alert.accessoryView = favorites
    alert.addButton(withTitle: "Clear History")
    alert.addButton(withTitle: "Cancel")
    if alert.runModal() == .alertFirstButtonReturn {
      let include = favorites.state == .on
      mutate { try $0.clear(includeFavorites: include) }
    }
  }
  @objc func quit() { NSApp.terminate(nil) }
  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    shutdownRequested = true
    stopTimers()
    return pendingWrites == 0 ? .terminateNow : .terminateLater
  }
  func applicationWillTerminate(_ notification: Notification) {
    invalidatePendingPaste()
    stopTimers()
    if let hotkey { UnregisterEventHotKey(hotkey) }
    if let monitor { NSEvent.removeMonitor(monitor) }
  }
  func stopTimers() {
    [timer, expiryTimer, storeRetryTimer].forEach { $0?.invalidate() }
    timer = nil
    expiryTimer = nil
    storeRetryTimer = nil
  }
  func registerShortcut() {
    if let hotkey {
      UnregisterEventHotKey(hotkey)
      self.hotkey = nil
    }
    if hotkeyHandler == nil {
      var event = EventTypeSpec(
        eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
      InstallEventHandler(
        GetApplicationEventTarget(),
        { _, _, _ in
          // Application-target hot keys arrive on the main thread: open in this same turn.
          if Thread.isMainThread {
            MainActor.assumeIsolated { ClipboardApp.shared.showHistoryFromShortcut() }
          } else {
            DispatchQueue.main.async {
              MainActor.assumeIsolated { ClipboardApp.shared.showHistoryFromShortcut() }
            }
          }
          return noErr
        }, 1, &event, nil, &hotkeyHandler)
    }
    let defaults = self.defaults
    let code = UInt32(defaults.object(forKey: "hotkeyCode") as? Int ?? 9)
    let modifiers = UInt32(
      defaults.object(forKey: "hotkeyModifiers") as? Int ?? (cmdKey | shiftKey))
    let status = RegisterEventHotKey(
      code, modifiers, EventHotKeyID(signature: 0x504F_5343, id: 1), GetApplicationEventTarget(), 0,
      &hotkey)
    shortcutProblem =
      status == noErr
      ? nil
      : "Global shortcut is already in use. Choose another shortcut in Clipboard History Settings."
    updateMenu()
    keyButton?.title = shortcutTitle()
  }
  func shortcutTitle() -> String {
    let defaults = self.defaults
    return "Shortcut: " + (defaults.string(forKey: "hotkeyTitle") ?? "⌘⇧V") + " (click to change)"
  }
  func installKeys() {
    monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) {
      [weak self] event in
      if event.type == .flagsChanged {
        MainActor.assumeIsolated { self?.popup?.modifiersChanged(event.modifierFlags) }
        return event
      }
      let consumed = MainActor.assumeIsolated { self?.handleKey(event) == nil }
      return consumed ? nil : event
    }
  }
  func handleKey(_ event: NSEvent) -> NSEvent? {
    if recordingShortcut {
      if event.keyCode == 53 {
        recordingShortcut = false
        keyButton?.title = shortcutTitle()
        return nil
      }
      let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
      guard flags.contains(.command) || flags.contains(.control) || flags.contains(.option) else {
        return nil
      }
      var carbon = 0
      if flags.contains(.command) { carbon |= cmdKey }
      if flags.contains(.shift) { carbon |= shiftKey }
      if flags.contains(.option) { carbon |= optionKey }
      if flags.contains(.control) { carbon |= controlKey }
      // Reserve Screenshot Studio's established shortcut.
      if event.keyCode == 19 && carbon == (cmdKey | shiftKey) {
        keyButton?.title = "⌘⇧2 belongs to Screenshot Studio. Choose another."
        return nil
      }
      let oldCode = defaults.object(forKey: "hotkeyCode")
      let oldMods = defaults.object(forKey: "hotkeyModifiers")
      let oldTitle = defaults.object(forKey: "hotkeyTitle")
      defaults.set(Int(event.keyCode), forKey: "hotkeyCode")
      defaults.set(carbon, forKey: "hotkeyModifiers")
      let title =
        (flags.contains(.control) ? "⌃" : "") + (flags.contains(.option) ? "⌥" : "")
        + (flags.contains(.shift) ? "⇧" : "") + (flags.contains(.command) ? "⌘" : "")
        + (event.charactersIgnoringModifiers?.uppercased() ?? "Key \(event.keyCode)")
      defaults.set(title, forKey: "hotkeyTitle")
      recordingShortcut = false
      problem = nil
      registerShortcut()
      if hotkey == nil {
        defaults.set(oldCode, forKey: "hotkeyCode")
        defaults.set(oldMods, forKey: "hotkeyModifiers")
        defaults.set(oldTitle, forKey: "hotkeyTitle")
        registerShortcut()
      }
      updateMenu()
      return nil
    }
    guard let popup, popup.window?.isKeyWindow == true else { return event }
    let flags = event.modifierFlags.intersection([.command, .option, .control])
    let cmd = event.modifierFlags.contains(.command)
    let searching = popup.window?.firstResponder is NSTextView
      && popup.window?.firstResponder !== popup.preview
    if event.keyCode == 53 {
      if searching && !popup.search.stringValue.isEmpty { popup.endSearch() } else { popup.dismiss() }
      return nil
    }
    // Repeating the hotkey key with its modifiers held cycles forward (handled by Carbon when
    // registered; this covers the case where the bezel already owns keyboard focus).
    if popup.holding, !flags.isEmpty, event.keyCode == UInt16(defaults.object(forKey: "hotkeyCode") as? Int ?? 9) {
      popup.advance()
      return nil
    }
    if cmd && event.charactersIgnoringModifiers?.lowercased() == "f" {
      popup.beginSearch()
      return nil
    }
    if cmd && event.charactersIgnoringModifiers?.lowercased() == "s" {
      popup.toggleFavoritesFilter()
      return nil
    }
    if [123, 125].contains(event.keyCode) && !searching {
      popup.move(1)
      return nil
    }
    if [124, 126].contains(event.keyCode) && !searching {
      popup.move(-1)
      return nil
    }
    if cmd && event.charactersIgnoringModifiers?.lowercased() == "c" && !searching {
      popup.copySelection()
      return nil
    }
    if cmd && event.charactersIgnoringModifiers?.lowercased() == "d" {
      popup.toggleFavorite()
      return nil
    }
    if cmd && event.keyCode == 51 && !searching {
      popup.deleteSelection()
      return nil
    }
    if event.keyCode == 36 || event.keyCode == 76 {
      popup.pasteSelection()
      return nil
    }
    // Typing any printable character starts an inline search.
    if !searching, flags.isEmpty, let typed = event.characters, !typed.isEmpty,
      typed.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }),
      event.keyCode != 51, event.keyCode != 117
    {
      popup.beginSearch(typed)
      return nil
    }
    return event
  }
  @objc func showSettings() {
    invalidatePendingPaste()
    popup?.window?.orderOut(nil)
    if settings == nil {
      let window = NSWindow(
        contentRect: CGRect(x: 0, y: 0, width: 570, height: 480), styleMask: [.titled, .closable],
        backing: .buffered, defer: false)
      window.title = "Clipboard History Settings"
      window.isReleasedWhenClosed = false
      let paused = NSButton(
        checkboxWithTitle: "Pause collection", target: self, action: #selector(togglePause))
      pausedButton = paused
      let login = NSButton(
        checkboxWithTitle: "Start at login", target: self, action: #selector(toggleLogin(_:)))
      loginButton = login
      let shortcut = ClipButton(shortcutTitle()) { [weak self] in
        self?.recordingShortcut = true
        self?.keyButton?.title = "Press a shortcut with ⌘, ⌃, or ⌥. Escape cancels."
      }
      keyButton = shortcut
      let text = NSTextView()
      text.isRichText = false
      text.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
      text.string = excluded.sorted().joined(separator: "\n")
      exclusions = text
      let scroll = NSScrollView()
      scroll.documentView = text
      scroll.hasVerticalScroller = true
      scroll.borderType = .bezelBorder
      scroll.heightAnchor.constraint(equalToConstant: 110).isActive = true
      clipColumn(
        [
          clipLabel("Local text history · 7 days · 500 recent + 100 favorites"),
          clipLabel(
            "Encrypted on disk. Favorites remain until deleted. 1 MiB per entry; 16 MiB total. No cloud sync."
          ), paused, login, shortcut, clipLabel("Excluded apps (one bundle identifier per line)"),
          scroll,
          clipRow([
            ClipButton("Add App…") { [weak self] in self?.addExcluded() },
            ClipButton("Save Exclusions") { [weak self] in self?.saveExclusions() },
          ]),
          clipRow([
            ClipButton("Accessibility…") {
              _ = AXIsProcessTrustedWithOptions(
                [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
            }, ClipButton("Retry Storage") { [weak self] in self?.retryStore(.manual) },
            ClipButton("Clear History…") { [weak self] in self?.clearHistory() },
          ]),
          clipLabel(
            "Password/temporary markers are skipped. Unmarked secrets cannot always be identified. Exclusions apply to future copies."
          ),
        ], in: window.contentView!)
      settings = window
    }
    exclusions?.string = excluded.sorted().joined(separator: "\n")
    pausedButton?.state = paused ? .on : .off
    loginButton?.state = FileManager.default.fileExists(atPath: loginPlist.path) ? .on : .off
    settings?.center()
    settings?.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }
  func addExcluded() {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.application]
    panel.directoryURL = URL(fileURLWithPath: "/Applications")
    if panel.runModal() == .OK, let url = panel.url, let id = Bundle(url: url)?.bundleIdentifier {
      let current = exclusions?.string ?? ""
      exclusions?.string = current + (current.isEmpty ? "" : "\n") + id
      saveExclusions()
    }
  }
  func saveExclusions() {
    let ids = (exclusions?.string ?? "").split(whereSeparator: \.isNewline).map {
      $0.trimmingCharacters(in: .whitespaces)
    }.filter { !$0.isEmpty }
    guard ids.count <= 200, ids.allSatisfy({ $0.utf8.count <= 512 && !$0.contains(" ") }) else {
      showNotice("Use one app bundle identifier per line, up to 200 apps.")
      return
    }
    defaults.set(Array(Set(ids)).sorted(), forKey: "excluded")
    lastChange = board.changeCount
  }
  /// The one LaunchAgent every writer produces (setup script and this toggle): restarted after a
  /// crash, never after a deliberate quit, which exits 0.
  static func loginAgent(executable: String) -> [String: Any] {
    [
      "Label": "com.productivity-os.clipboard-history",
      "ProgramArguments": [executable, "--background"],
      "RunAtLoad": true,
      "KeepAlive": ["SuccessfulExit": false],
      "ProcessType": "Interactive",
      "ThrottleInterval": 30,
      "LimitLoadToSessionType": "Aqua",
    ]
  }
  static func writeLoginAgent(executable: String, to url: URL) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    guard (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true
    else { throw ClipError("Unsafe login registration path") }
    try PropertyListSerialization.data(
      fromPropertyList: loginAgent(executable: executable), format: .xml, options: 0
    ).write(to: url, options: .atomic)
  }
  @objc func toggleLogin(_ sender: NSButton) {
    do {
      if sender.state == .on {
        guard let executable = Bundle.main.executablePath else {
          throw ClipError("Cannot locate the Clipboard History executable")
        }
        // Written atomically and never loaded from here: launchd starts it at the next login.
        try Self.writeLoginAgent(executable: executable, to: loginPlist)
      } else if FileManager.default.fileExists(atPath: loginPlist.path) {
        // Delete only. Unloading from inside the app could stop this very process.
        try FileManager.default.removeItem(at: loginPlist)
      }
    } catch {
      sender.state = FileManager.default.fileExists(atPath: loginPlist.path) ? .on : .off
      showNotice(error.localizedDescription)
    }
  }
}
