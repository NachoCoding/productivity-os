import AppKit

@MainActor func runShelfUITests(root: URL) async throws {
  let store = try ShelfStore(root: root.appendingPathComponent("ui-regressions"))
  let id = try store.create(), app = DropShelfApp()
  app.store = store
  let entries = try (0..<60).map { try ShelfItem.text("Visible item \($0)") }
  try store.add(entries, to: id)
  let controller = ShelfController(app: app, id: id)
  app.controllers[id] = controller
  controller.expanded = true
  controller.present(activate: false)
  defer { controller.closePreview(); controller.window?.close() }
  check(controller.tiles.count == entries.count, "Expanded shelf includes items beyond the first twelve")
  let first = controller.tiles[entries[0].id]!
  check(first.acceptsFirstMouse(for: nil) && !first.mouseDownCanMoveWindow,
    "Inactive shelf tiles accept the first click as an item interaction")
  check(first.hitTest(NSPoint(x: first.frame.minX + 50, y: first.frame.minY + 50)) === first,
    "Decorative card content forwards its mouse hit to the draggable tile")
  let panel = controller.window!
  check(panel.collectionBehavior.contains(.canJoinAllSpaces)
    && panel.collectionBehavior.contains(.canJoinAllApplications)
    && panel.collectionBehavior.contains(.fullScreenAuxiliary)
    && !panel.collectionBehavior.contains(.moveToActiveSpace),
    "Shelf joins other apps, desktop Spaces, and fullscreen Spaces without moving out of previous Spaces")
  check(panel.level == .floating && panel.styleMask.contains(.nonactivatingPanel)
    && !panel.hidesOnDeactivate,
    "Shelf stays floating and visible when another app becomes active")

  func verifyFocusPreservation() async throws {
    let wasActive = NSApp.isActive, previousKey = NSApp.keyWindow
    let previousApp = NSWorkspace.shared.frontmostApplication
    guard let otherApp = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first else {
      throw ShelfError("Finder is unavailable for the app-switch fixture")
    }
    let focusWindow = NSWindow(contentRect: NSRect(x: 60, y: 60, width: 180, height: 100),
      styleMask: [.titled], backing: .buffered, defer: false)
    focusWindow.title = "Drop Shelf focus fixture"
    focusWindow.isReleasedWhenClosed = false
    defer {
      focusWindow.orderOut(nil); focusWindow.close()
      if wasActive { NSApp.activate(ignoringOtherApps: true); previousKey?.makeKey() }
      else if let previousApp {
        NSApp.yieldActivation(to: previousApp); previousApp.activate(from: .current, options: [])
      }
    }
    NSApp.activate(ignoringOtherApps: true)
    focusWindow.makeKeyAndOrderFront(nil)
    try await waitForShelfCondition("focus fixture activation") { NSApp.isActive && NSApp.keyWindow === focusWindow }
    controller.present(activate: false)
    try await Task.sleep(nanoseconds: 30_000_000)
    check(NSApp.keyWindow === focusWindow && !panel.isKeyWindow,
      "Presenting a shelf without activation preserves the existing key window")

    controller.select(entries[0].id, extend: false)
    controller.select(entries[1].id, extend: true)
    controller.scrollView.contentView.scroll(to: NSPoint(x: 0, y: 468))
    controller.scrollView.reflectScrolledClipView(controller.scrollView.contentView)
    let expectedItems = controller.items, expectedSelection = controller.selected
    let expectedFrame = panel.frame, expectedScroll = controller.scrollView.documentVisibleRect.origin
    NSApp.yieldActivation(to: otherApp); otherApp.activate(from: .current, options: [])
    try await waitForShelfCondition("switching from the shelf fixture to Finder") {
      !NSApp.isActive && NSWorkspace.shared.frontmostApplication?.processIdentifier == otherApp.processIdentifier
    }
    try await Task.sleep(nanoseconds: 150_000_000)
    let visibleWindows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    check(panel.isVisible && visibleWindows.contains { ($0[kCGWindowNumber as String] as? Int) == panel.windowNumber },
      "Changing to Finder leaves the existing shelf visible on screen")
    panel.orderOut(nil)
    controller.present(activate: false)
    try await Task.sleep(nanoseconds: 50_000_000)
    print("SHELF_FOCUS active=\(NSApp.isActive) key=\(panel.isKeyWindow) visible=\(panel.isVisible) hidden=\(NSApp.isHidden) front=\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "unbundled")")
    check(!NSApp.isActive && !panel.isKeyWindow && panel.isVisible
      && NSWorkspace.shared.frontmostApplication?.processIdentifier == otherApp.processIdentifier,
      "Presenting a shelf during another app's activity keeps that app's activation and keyboard focus")
    controller.present(activate: true)
    try await Task.sleep(nanoseconds: 50_000_000)
    check(!NSApp.isActive && panel.isKeyWindow
      && NSWorkspace.shared.frontmostApplication?.processIdentifier == otherApp.processIdentifier,
      "A keyboard-focused shelf (the shortcut) takes keys without activating Drop Shelf or the frontmost app changing")
    NSApp.activate(ignoringOtherApps: true)
    focusWindow.makeKeyAndOrderFront(nil)
    try await waitForShelfCondition("test app reactivation") { NSApp.isActive && NSApp.keyWindow === focusWindow }
    check(panel.isVisible && panel.frame == expectedFrame && controller.items == expectedItems
      && controller.selected == expectedSelection && controller.scrollView.documentVisibleRect.origin == expectedScroll,
      "Switching away and back preserves shelf content, selection, position, and scroll")
    controller.selected = []
    controller.scrollView.contentView.scroll(to: .zero)
    controller.scrollView.reflectScrolledClipView(controller.scrollView.contentView)
    controller.render()
  }
  try await verifyFocusPreservation()

  func mouse(_ type: NSEvent.EventType, flags: NSEvent.ModifierFlags = []) -> NSEvent {
    let point = first.convert(NSPoint(x: 20, y: 20), to: nil)
    return NSEvent.mouseEvent(with: type, location: point, modifierFlags: flags,
      timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: controller.window!.windowNumber,
      context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
  }
  controller.select(entries[0].id, extend: false)
  controller.select(entries[1].id, extend: true)
  first.mouseDown(with: mouse(.leftMouseDown))
  check(controller.selected == Set(entries.prefix(2).map(\.id))
    && first.dragItems().map(\.id) == entries.prefix(2).map(\.id),
    "Mouse down on a selected item preserves the complete multi-item drag")
  check(controller.summaryLabel.stringValue.contains("2 selected"),
    "Selection feedback updates immediately without rebuilding the shelf")
  first.mouseUp(with: mouse(.leftMouseUp))
  check(controller.selected == [entries[0].id], "Click without dragging selects only the clicked item")
  first.mouseDown(with: mouse(.leftMouseDown, flags: .command))
  first.mouseUp(with: mouse(.leftMouseUp, flags: .command))
  check(controller.selected.isEmpty, "Command click toggles selection once per gesture")

  controller.scrollView.contentView.scroll(to: NSPoint(x: 0, y: 468))
  controller.scrollView.reflectScrolledClipView(controller.scrollView.contentView)
  let origin = controller.scrollView.documentVisibleRect.origin
  let rootView = controller.rootView
  let scroll = controller.scrollView
  controller.message = "Fixture status"
  controller.render()
  check(controller.rootView === rootView && controller.scrollView === scroll
    && controller.tiles[entries[0].id] === first,
    "Status changes preserve the existing root, scroll view, and tile objects")
  check(controller.scrollView.documentVisibleRect.origin == origin,
    "Status refresh does not reset the user's scroll position")
  controller.beginInteraction()
  let appended = try ShelfItem.text("Arrived while dragging")
  try store.add([appended], to: id)
  controller.render()
  check(controller.activeGesture && controller.deferredRender && controller.tiles[appended.id] == nil
    && first.superview != nil,
    "Import completion defers structural updates while a drag source is active")
  controller.endInteraction()
  check(!controller.activeGesture && !controller.deferredRender && controller.tiles[appended.id] != nil,
    "Deferred import appears as soon as the gesture finishes")
  check(controller.scrollView.documentVisibleRect.origin == origin && controller.tiles[entries[0].id] === first,
    "Appending an imported item preserves scroll position and existing tiles")

  let missingURL = root.appendingPathComponent("ui-missing-file.txt")
  try Data("temporary fixture".utf8).write(to: missingURL)
  let missing = try ShelfItem.file(missingURL)
  try FileManager.default.removeItem(at: missingURL)
  controller.message = nil
  check(controller.writer(missing) == nil && controller.summaryLabel.stringValue.contains("removed"),
    "Unavailable drag source reports its error immediately")

  // Measure warm status/selection paths separately from first layout and thumbnail IO.
  var statusTimes: [Double] = [], selectionTimes: [Double] = []
  for cycle in 0..<40 {
    var start = ProcessInfo.processInfo.systemUptime
    controller.message = "Updated \(cycle)"; controller.render()
    statusTimes.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
    start = ProcessInfo.processInfo.systemUptime
    controller.select(entries[cycle % entries.count].id, extend: false)
    selectionTimes.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
  }
  let statusP95 = statusTimes.sorted()[37], selectionP95 = selectionTimes.sorted()[37]
  print("UI_PERFORMANCE items=\(controller.items.count) status_p95_ms=\(statusP95) selection_p95_ms=\(selectionP95)")
  check(statusP95 < 16 && selectionP95 < 16, "Warm status and selection updates remain below 16 ms at p95")

  var openTimes: [Double] = [], acceptTimes: [Double] = []
  app.imports.resolver = { entry in .init(items: [try .text(entry.text!)]) }
  for cycle in 0..<20 {
    controller.window?.orderOut(nil)
    var start = ProcessInfo.processInfo.systemUptime
    _ = await app.open(id, activate: false)
    openTimes.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
    start = ProcessInfo.processInfo.systemUptime
    try app.imports.accept(entries: [ShelfIngest.Entry(text: "Warm acceptance \(cycle)")], to: id)
    acceptTimes.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
    check(controller.summaryLabel.stringValue.contains("Adding"), "Warm accepted drop displays progress synchronously")
    try await waitForShelfImports(app, "warm acceptance measurement")
  }
  let openP95 = openTimes.sorted()[18], acceptP95 = acceptTimes.sorted()[18]
  print("UI_PERFORMANCE warm_open_p95_ms=\(openP95) accepted_drop_p95_ms=\(acceptP95)")
  check(openP95 < 100 && acceptP95 < 100, "Warm opening and accepted-drop feedback remain below 100 ms at p95")

  let displays = [NSRect(x: -1440, y: 0, width: 1440, height: 900), NSRect(x: 0, y: 0, width: 1512, height: 945)]
  let visible = displays[0].insetBy(dx: 0, dy: 30)
  let expanded = ShelfPlacement.preferredSize(expanded: true, in: visible)
  let placed = ShelfPlacement.frame(size: expanded, in: visible, near: NSPoint(x: -5, y: 890))
  check(visible.contains(placed), "Expanded shelf fits a display with a negative origin")
  let reopened = ShelfPlacement.frame(size: expanded, in: displays[1], preserving: placed)
  check(displays[1].contains(reopened), "Reopening after a display is removed clamps the shelf to an available display")
  check(ShelfPlacement.screenIndex(frames: displays, near: NSPoint(x: -100, y: 300), preserving: nil) == 0,
    "Incoming drag chooses the display containing the pointer")
  check(ShelfPlacement.preferredSize(expanded: true, in: NSRect(x: 0, y: 0, width: 400, height: 700))
    == NSSize(width: 280, height: 216), "Narrow display falls back to a compact shelf that fits")

  // Inject completion callbacks: no Quick Look process or real browser is needed for cache policy.
  var completions: [ShelfThumbnailCache.Key: @MainActor (NSImage?) -> Void] = [:]
  var cancelled = Set<ShelfThumbnailCache.Key>()
  var delivered: [ShelfThumbnailCache.Key] = []
  let keys = (0..<8).map { index in
    ShelfThumbnailCache.Key(id: UUID(), url: root.appendingPathComponent("thumb-\(index).png"), scale: 2)
  }
  let cache = ShelfThumbnailCache(capacity: 3) { key, completion in
    completions[key] = completion
    return { cancelled.insert(key) }
  }
  let image = NSImage(size: NSSize(width: 4, height: 4))
  cache.update(Array(keys.prefix(4))) { key, _ in delivered.append(key) }
  check(cache.activeCount == 2 && completions.count == 2, "Thumbnail generation starts at most two requests")
  let late = completions[keys[0]]!
  cache.update(Array(keys.suffix(4))) { key, _ in delivered.append(key) }
  check(cancelled.contains(keys[0]) && cancelled.contains(keys[1]) && cache.activeCount == 2,
    "Scrolling cancels requests outside the visible thumbnail set")
  late(image)
  check(delivered.isEmpty && cache.cacheCount == 0, "Obsolete thumbnail completion cannot update the current shelf")
  for key in keys.suffix(4) { completions[key]?(image) }
  check(delivered == Array(keys.suffix(4)) && cache.cacheCount == 3 && cache.activeCount == 0,
    "Newly visible thumbnails load while the cache stays bounded")
  cache.update([keys[0], keys[1]]) { _, _ in }
  cache.cancelAll()
  check(cache.activeCount == 0, "Closing the shelf cancels its outstanding thumbnail jobs")
  try await runShelfDisplayTests(root: root)
}

@MainActor private func runShelfDisplayTests(root: URL) async throws {
  let store = try ShelfStore(root: root.appendingPathComponent("display-regressions"))
  let id = try store.create(), app = DropShelfApp()
  app.store = store
  // Two logical monitor bounds share the actual display so this integration fixture also runs
  // on a one-monitor machine; physical monitor placement is covered separately above.
  let actual = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
  let width = max(280, actual.width / 2), height = max(216, actual.height)
  let leftBounds = NSRect(x: actual.minX, y: actual.minY, width: width, height: height)
  let rightBounds = NSRect(x: actual.maxX - width, y: actual.minY, width: width, height: height)
  let firstDisplay = ShelfDisplay(id: 101, frame: leftBounds, visibleFrame: leftBounds)
  let secondDisplay = ShelfDisplay(id: 202, frame: rightBounds, visibleFrame: rightBounds)
  var displays = [firstDisplay, secondDisplay]
  app.displayProvider = { displays }
  let pixel = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 3, pixelsHigh: 2, bitsPerSample: 8,
    samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
  let png = pixel.representation(using: .png, properties: [:])!
  let imageURL = root.appendingPathComponent("secondary-display-image.png")
  try png.write(to: imageURL)
  let shared = [try ShelfItem.text("Shared display text"), try .text("https://example.com/shared"),
    try .file(imageURL, image: true)]
  try store.add(shared, to: id)
  let activeBefore = NSApp.isActive, keyBefore = NSApp.keyWindow
  _ = await app.open(id, near: NSPoint(x: leftBounds.midX, y: leftBounds.midY), activate: false)
  let opened = await app.open(id, near: NSPoint(x: rightBounds.midX, y: rightBounds.midY), activate: false)
  defer { for copy in app.allControllers { copy.closePreview(); copy.window?.close() } }
  let initial = app.shelfControllers(id)
  check(initial.count == 2 && Set(initial.compactMap { $0.display?.id }) == [101, 202],
    "One logical shelf opens exactly one panel on each connected display")
  check(opened?.display?.id == 202, "Opening near a pointer returns the corresponding display's shelf copy")
  check(store.shelves.count == 1 && initial.allSatisfy { $0.id == id && $0.items == shared },
    "Display copies share shelf and item identities without duplicating stored data")
  check(NSApp.isActive == activeBefore && NSApp.keyWindow === keyBefore,
    "Opening all display copies without activation preserves current keyboard focus")
  let left = initial.first { $0.display?.id == 101 }!, right = initial.first { $0.display?.id == 202 }!
  check(left.presentation === right.presentation, "All display copies share the same presentation state")
  check(initial.allSatisfy { copy in
    guard let window = copy.window, let display = copy.display else { return false }
    return window.isVisible && display.visibleFrame.contains(window.frame)
      && window.collectionBehavior.contains(.canJoinAllSpaces)
      && window.collectionBehavior.contains(.canJoinAllApplications)
  }, "Every display copy stays visible within its assigned monitor and across apps and Spaces")
  left.select(shared[0].id, extend: false)
  check(right.selected == [shared[0].id] && initial.allSatisfy { $0.summaryLabel.stringValue.contains("1 selected") },
    "Selection on one display updates selection and feedback on every copy")
  right.expanded = true; app.renderShelf(id)
  check(initial.allSatisfy(\.expanded), "Expanding from a secondary display updates all shelf copies")
  check(right.rootView?.acceptsDrop(types: [.string], sourceShelfID: left.id) == false
    && right.rootView?.acceptsDrop(types: [.string], sourceShelfID: UUID()) == true,
    "Dragging between copies of the same shelf is rejected while other shelves remain valid sources")
  let textWriter = right.writer(shared[0]) as? NSPasteboardItem
  let linkWriter = right.writer(shared[1]) as? NSPasteboardItem
  let imageWriter = right.writer(shared[2]) as? NSPasteboardItem
  check(textWriter?.string(forType: .string) == shared[0].value
    && linkWriter?.string(forType: .URL) == shared[1].value,
    "Secondary display exports exact text and link representations")
  let exportedImageURL = imageWriter?.string(forType: .fileURL).flatMap(URL.init(string:))
  check(exportedImageURL?.resolvingSymlinksInPath() == imageURL.resolvingSymlinksInPath() && imageWriter?.data(forType: .png) == png,
    "Secondary display exports both the saved image file and its original PNG pixels")

  let board = NSPasteboard(name: .init("shelf-display-drop-\(UUID().uuidString)"))
  defer { board.releaseGlobally() }
  let gate = ShelfImportGate()
  app.imports.resolver = { try await gate.resolve($0) }
  for (index, source) in [right, left].enumerated() {
    let value = "Imported through display \(index)"
    board.clearContents(); board.setString(value, forType: .string)
    check(source.ingest(board), "Each display copy accepts a drop into its shared shelf")
    check(app.shelfControllers(id).allSatisfy { $0.pendingImages == 1 && $0.summaryLabel.stringValue.contains("Adding") },
      "Pending drop feedback immediately appears on all display copies")
    try await waitForShelfCondition("mirrored import resolver") { gate.keys.contains(value) }
    gate.finish(value, items: [try .text(value)])
    try await waitForShelfImports(app, "mirrored import completion")
    check(app.shelfControllers(id).allSatisfy { $0.items.count == shared.count + index + 1 && $0.items.last?.value == value },
      "Drop completed through either display updates all copies exactly once")
  }
  let removed = right.items.last!.id
  right.select(removed, extend: false); right.removeAction()
  try await waitForShelfCondition("removal from every shelf copy") {
    app.shelfControllers(id).allSatisfy { !$0.items.contains { $0.id == removed } }
  }
  await app.waitForStore()
  check(app.shelfControllers(id).allSatisfy { $0.selected.isEmpty && $0.items.count == shared.count + 1 },
    "Removal from a secondary display updates content and selection on every copy")
  right.change { $0.name = "Shared across monitors" }
  try await waitForShelfCondition("shared shelf rename") {
    app.shelfControllers(id).allSatisfy { $0.window?.title.contains("Shared across monitors") == true }
  }
  await app.waitForStore()
  check(store.shelves.count == 1 && store.shelves.first?.name == "Shared across monitors",
    "Renaming from a secondary display persists one name for all copies")

  let originalRight = right
  left.beginInteraction()
  displays = [secondDisplay]; app.synchronizeDisplays()
  check(app.shelfControllers(id).count == 2 && app.shelfControllers(id).contains { $0 === left },
    "Monitor reconciliation retains an active drag source until the gesture finishes")
  left.endInteraction()
  try await waitForShelfCondition("deferred monitor removal") { app.shelfControllers(id).count == 1 }
  check(app.shelfControllers(id).first === originalRight && originalRight.window?.isVisible == true,
    "Removing a monitor preserves the surviving shelf panel and its contents")
  displays = [secondDisplay, firstDisplay]; app.synchronizeDisplays()
  check(app.shelfControllers(id).count == 2 && Set(app.shelfControllers(id).compactMap { $0.display?.id }) == [101, 202]
    && app.shelfControllers(id).contains { $0 === originalRight },
    "Reconnecting a monitor adds its missing copy without replacing the surviving panel")
  let beforeReorder = Set(app.shelfControllers(id).map(ObjectIdentifier.init))
  displays = [firstDisplay, secondDisplay]; app.synchronizeDisplays()
  check(Set(app.shelfControllers(id).map(ObjectIdentifier.init)) == beforeReorder && store.shelves.count == 1,
    "Monitor enumeration changes do not duplicate panels or logical shelves")
  check(app.shelfControllers(id).allSatisfy { $0.items == originalRight.items && $0.expanded },
    "Hotplug and monitor reordering preserve shared content and expanded state")
  displays = []; app.synchronizeDisplays()
  check(app.shelfControllers(id).count == 2 && app.shelfControllers(id).allSatisfy { $0.window?.isVisible == false },
    "Temporarily losing all displays hides the copies without losing their shared state")
  displays = [firstDisplay, secondDisplay]; app.synchronizeDisplays()
  check(app.shelfControllers(id).count == 2 && app.shelfControllers(id).allSatisfy { $0.window?.isVisible == true },
    "Returning displays restore the existing shelf copies")
  let closing = app.shelfControllers(id)
  originalRight.closeShelf()
  try await waitForShelfCondition("closing every display copy") {
    store.shelves.first { $0.id == id }?.closed == true && app.shelfControllers(id).isEmpty
  }
  await app.waitForStore()
  check(closing.allSatisfy { $0.window?.isVisible == false } && store.shelves.count == 1,
    "Closing from either display closes every copy into a single recent shelf")
  displays = [firstDisplay]; app.synchronizeDisplays()
  check(app.shelfControllers(id).isEmpty && store.shelves.first?.closed == true,
    "Later display changes do not reopen a shelf from closed history")
}
