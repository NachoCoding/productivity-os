import AppKit
import QuickLookThumbnailing

/// One logical shelf can have a panel on each display without duplicating its contents.
@MainActor final class ShelfPresentationState {
  var expanded = false
  var selected = Set<UUID>()
  var message: String?
  /// Shared by every display copy: one thumbnail request and one resolved URL/icon per item.
  lazy var thumbnails = ShelfThumbnailCache()
  var resolvedURLs: [UUID: URL] = [:]
  var resolving = Set<UUID>()
  var icons: [UUID: NSImage] = [:]
  /// Rounded stack images, keyed by item and reused while the source thumbnail is unchanged.
  var rounded: [UUID: (source: NSImage, image: NSImage)] = [:]
  func forget(keeping ids: Set<UUID>) {
    resolvedURLs = resolvedURLs.filter { ids.contains($0.key) }; resolving.formIntersection(ids)
    icons = icons.filter { ids.contains($0.key) }; rounded = rounded.filter { ids.contains($0.key) }
  }
}

struct ShelfDisplay: Equatable {
  let id: UInt32
  let frame: NSRect
  let visibleFrame: NSRect
  @MainActor static var current: [ShelfDisplay] {
    NSScreen.screens.compactMap { screen in
      guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
      return ShelfDisplay(id: number.uint32Value, frame: screen.frame, visibleFrame: screen.visibleFrame)
    }
  }
}

/// Placement uses AppKit points, including screens with negative origins.
enum ShelfPlacement {
  static func preferredSize(expanded: Bool, in bounds: NSRect?) -> NSSize {
    let compact = NSSize(width: 280, height: 216), large = NSSize(width: 440, height: 430)
    guard expanded else { return compact }
    if let bounds, bounds.width < large.width || bounds.height < large.height { return compact }
    return large
  }
  static func frame(size: NSSize, in bounds: NSRect, near point: NSPoint? = nil, preserving old: NSRect? = nil) -> NSRect {
    var x = old?.minX ?? bounds.midX - size.width / 2
    var y = old.map { $0.maxY - size.height } ?? bounds.midY - size.height / 2
    if let point {
      x = point.x + 24
      if x + size.width > bounds.maxX, point.x - 24 - size.width >= bounds.minX { x = point.x - 24 - size.width }
      y = point.y - size.height / 2
    }
    x = bounds.width >= size.width ? min(max(x, bounds.minX), bounds.maxX - size.width) : bounds.minX
    y = bounds.height >= size.height ? min(max(y, bounds.minY), bounds.maxY - size.height) : bounds.maxY - size.height
    return NSRect(origin: NSPoint(x: x, y: y), size: size)
  }
  static func screenIndex(frames: [NSRect], near point: NSPoint?, preserving old: NSRect?, preferred: Int? = nil) -> Int? {
    guard !frames.isEmpty else { return nil }
    if let point, let containing = frames.firstIndex(where: { $0.contains(point) }) { return containing }
    if point == nil, let old {
      let areas = frames.map { frame -> CGFloat in
        let overlap = frame.intersection(old)
        return overlap.isNull ? 0 : overlap.width * overlap.height
      }
      let maximum = areas.max() ?? 0
      if maximum > 0 {
        if let preferred, areas.indices.contains(preferred), areas[preferred] == maximum { return preferred }
        return areas.firstIndex(of: maximum)
      }
    }
    let target = point ?? old.map { NSPoint(x: $0.midX, y: $0.midY) } ?? NSPoint(x: frames[0].midX, y: frames[0].midY)
    func distance(_ frame: NSRect) -> CGFloat {
      let dx = max(max(frame.minX - target.x, 0), target.x - frame.maxX)
      let dy = max(max(frame.minY - target.y, 0), target.y - frame.maxY)
      return dx * dx + dy * dy
    }
    return frames.indices.min { distance(frames[$0]) < distance(frames[$1]) }
  }
}

/// Thumbnails for every display copy of a shelf. Each copy is a client with its own visible set;
/// a request runs once while any client wants it and is cancelled only when none does.
@MainActor final class ShelfThumbnailCache {
  struct Key: Hashable {
    let id: UUID
    let url: URL
    let scale: CGFloat
  }
  typealias Loader = (Key, @escaping @MainActor (NSImage?) -> Void) -> (() -> Void)
  private struct Work { let token: UUID; var cancel: () -> Void }
  private struct Client {
    weak var owner: AnyObject?
    var keys: [Key]
    var wanted: Set<Key>
    var onImage: (Key, NSImage) -> Void
  }
  private let capacity: Int
  private let loader: Loader
  private var cache: [Key: NSImage] = [:]
  private var recent: [Key] = []
  private var active: [Key: Work] = [:]
  private var failed = Set<Key>()
  private var clients: [ObjectIdentifier: Client] = [:]
  private var order: [ObjectIdentifier] = []
  private var wanted = Set<Key>()
  /// Requests in priority order; the copy updated last (being scrolled) goes first.
  private var queue: [Key] = []
  private let soleClient = NSObject()
  var activeCount: Int { active.count }
  var cacheCount: Int { cache.count }
  init(capacity: Int = 48, loader: Loader? = nil) {
    self.capacity = max(1, capacity)
    self.loader = loader ?? Self.load
  }
  deinit { for task in active.values { task.cancel() } }
  private static func load(_ key: Key, completion: @escaping @MainActor (NSImage?) -> Void) -> (() -> Void) {
    let request = QLThumbnailGenerator.Request(fileAt: key.url, size: NSSize(width: 80, height: 80), scale: key.scale, representationTypes: .thumbnail)
    QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, _ in
      DispatchQueue.main.async { completion(representation?.nsImage) }
    }
    return { QLThumbnailGenerator.shared.cancel(request) }
  }
  /// `owner` identifies a display copy; callers with a single view may omit it.
  func update(_ keys: [Key], for owner: AnyObject? = nil, onImage: @escaping (Key, NSImage) -> Void) {
    let owner = owner ?? soleClient, id = ObjectIdentifier(owner)
    clients[id] = Client(owner: owner, keys: keys, wanted: Set(keys), onImage: onImage)
    order.removeAll { $0 == id }; order.insert(id, at: 0)
    release()
    var seen = Set<Key>()
    let fresh = keys.filter { seen.insert($0).inserted && cache[$0] == nil && active[$0] == nil && !failed.contains($0) }
    queue = fresh + queue.filter { !seen.contains($0) && wanted.contains($0) }
    for key in keys {
      if let image = cache[key] { touch(key); onImage(key, image) }
    }
    pump()
  }
  /// A closed or retired display copy stops wanting its thumbnails.
  func remove(_ owner: AnyObject) {
    clients.removeValue(forKey: ObjectIdentifier(owner))
    release(); pump()
  }
  private func release() {
    for (id, client) in clients where client.owner == nil { clients.removeValue(forKey: id) }
    order.removeAll { clients[$0] == nil }
    wanted = clients.values.reduce(into: Set<Key>()) { $0.formUnion($1.wanted) }
    failed.formIntersection(wanted)
    for (key, work) in Array(active) where !wanted.contains(key) {
      active.removeValue(forKey: key); work.cancel()
    }
  }
  private func touch(_ key: Key) { recent.removeAll { $0 == key }; recent.append(key) }
  private func pump() {
    while active.count < 2, !queue.isEmpty {
      let key = queue.removeFirst(), token = UUID()
      guard wanted.contains(key), active[key] == nil, cache[key] == nil else { continue }
      active[key] = Work(token: token, cancel: {})
      let cancel = loader(key) { [weak self] image in
        guard let self, self.active[key]?.token == token else { return }
        self.active.removeValue(forKey: key)
        if let image {
          self.cache[key] = image; self.touch(key)
          while self.recent.count > self.capacity { self.cache.removeValue(forKey: self.recent.removeFirst()) }
          for id in self.order { if let client = self.clients[id], client.owner != nil, client.wanted.contains(key) { client.onImage(key, image) } }
        } else { self.failed.insert(key) }
        self.pump()
      }
      if active[key]?.token == token { active[key]?.cancel = cancel }
    }
  }
  func cancelAll() {
    let work = Array(active.values)
    active.removeAll(); clients.removeAll(); order.removeAll(); queue.removeAll(); wanted.removeAll()
    for task in work { task.cancel() }
  }
}

/// A top-origin document keeps appends from moving the scroll position.
@MainActor final class ShelfGridView: NSView {
  override var isFlipped: Bool { true }
}

/// Advertise pixels immediately; read them only if the destination requests them.
final class ShelfImagePasteboardProvider: NSObject, NSPasteboardItemDataProvider {
  let url: URL
  init(url: URL) { self.url = url }
  func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
    guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
      size <= ShelfStore.maxImageBytes, let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return }
    item.setData(data, forType: type)
  }
}
