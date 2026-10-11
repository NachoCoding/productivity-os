import AppKit
import ImageIO
import UniformTypeIdentifiers

struct StudioError: LocalizedError {
  let message: String
  init(_ message: String) { self.message = message }
  var errorDescription: String? { message }
}

enum Limits {
  static let pixels = 100_000_000
  static let dimension = 60_000
  static let cache = 512 * 1024 * 1024
  static func validate(_ size: CGSize) throws {
    guard size.width.isFinite, size.height.isFinite, size.width >= 1, size.height >= 1,
      size.width <= CGFloat(dimension), size.height <= CGFloat(dimension),
      size.width * size.height <= CGFloat(pixels)
    else {
      throw StudioError(
        "Image exceeds 100 megapixels or 60,000 pixels per side. Resize it before opening.")
    }
  }
}

struct Ink: Codable, Equatable {
  var r: Double = 0.98, g: Double = 0.25, b: Double = 0.29, a: Double = 1
  var color: NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: a) }
  init(_ color: NSColor = .systemRed) {
    let c = color.usingColorSpace(.sRGB) ?? .red
    r = c.redComponent
    g = c.greenComponent
    b = c.blueComponent
    a = c.alphaComponent
  }
}

enum Tool: String, Codable, CaseIterable {
  case select = "Select / Crop"
  case arrow = "Arrow"
  case text = "Text"
  case rectangle = "Rectangle"
  case highlight = "Highlight"
  case redact = "Solid Redact"
  case ellipse = "Ellipse"
  case pen = "Draw"
  case step = "Numbered Step"
  case spotlight = "Spotlight"
  case magnify = "Magnifier"
  case blur = "Blur"
  case pixelate = "Pixelate"
  case erase = "Background Eraser"
  case ruler = "Ruler"
  case curvedArrow = "Curved Arrow"
  case callout = "Text Callout"
}

struct Mark: Codable, Equatable, Identifiable {
  var id = UUID()
  var tool: Tool
  var rect: CGRect
  var end: CGPoint?
  var points: [CGPoint] = []
  var text = ""
  var ink = Ink()
  var width: CGFloat = 4
  var fontSize: CGFloat = 28
  var group: UUID?
  mutating func resize(to next: CGRect) {
    let previous = rect
    func map(_ p: CGPoint) -> CGPoint {
      CGPoint(
        x: next.minX + (p.x - previous.minX) * next.width / max(1, previous.width),
        y: next.minY + (p.y - previous.minY) * next.height / max(1, previous.height))
    }
    points = points.map(map)
    end = end.map(map)
    rect = next
  }
}

struct Layer: Codable, Equatable, Identifiable {
  var id = UUID()
  var asset: String
  var rect: CGRect
  var opacity: CGFloat = 1
}

struct Backdrop: Codable, Equatable {
  var enabled = false
  var padding: CGFloat = 64
  var radius: CGFloat = 20
  var shadow = true
  var first = Ink(NSColor(red: 0.36, green: 0.32, blue: 0.85, alpha: 1))
  var second = Ink(NSColor(red: 0.12, green: 0.65, blue: 0.80, alpha: 1))
}

struct Scene: Codable, Equatable {
  var version = 1
  var size: CGSize
  var scale: CGFloat = 1
  var layers: [Layer]
  var marks: [Mark] = []
  var backdrop = Backdrop()
}

/// Bounded decoded-image cache. Undo stores scene commands, never image copies.
/// New assets are served from memory at once; their PNG (read by crash recovery and projects) is
/// written on a background queue. Callers pass compact images, never crops that pin a larger parent.
final class ImageStore {
  let root: URL
  private static var cache: [String: CGImage] = [:]
  private static var order: [String] = []
  private static var bytes = 0
  /// Added but not yet on disk (or whose write failed): never evicted, so the document stays usable.
  private static var pending: [String: CGImage] = [:]
  private static let lock = NSLock()
  private static let writes = DispatchQueue(
    label: "com.productivity-os.screenshot-studio.asset-writes", qos: .utility)
  init(root: URL, create: Bool = true) throws {
    self.root = root
    if create {
      try FileManager.default.createDirectory(
        at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
    let info = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
    guard info.isDirectory == true, info.isSymbolicLink != true else {
      throw StudioError("Invalid asset directory")
    }
  }
  private var prefix: String { root.path + "/" }
  func add(_ image: CGImage) throws -> String {
    try Limits.validate(CGSize(width: image.width, height: image.height))
    let name = UUID().uuidString + ".png"
    let key = prefix + name
    let url = root.appendingPathComponent(name)
    Self.lock.lock()
    Self.pending[key] = image
    Self.lock.unlock()
    Self.writes.async {
      guard (try? encode(image, to: url, type: UTType.png.identifier)) != nil else { return }
      Self.lock.lock()
      defer { Self.lock.unlock() }
      // A purged (discarded) document is not cached again.
      if Self.pending.removeValue(forKey: key) != nil { Self.insert(image, for: key) }
    }
    return name
  }
  /// Waits for queued asset writes. Call before reading this store's files directly.
  func waitForWrites() { Self.writes.sync {} }
  /// Every asset of this store is on disk afterwards, or this throws (e.g. the disk is full).
  func flush() throws {
    waitForWrites()
    Self.lock.lock()
    let stuck = Self.pending.filter { $0.key.hasPrefix(prefix) }
    Self.lock.unlock()
    for (key, image) in stuck {
      try encode(
        image, to: root.appendingPathComponent(String(key.dropFirst(prefix.count))),
        type: UTType.png.identifier)
      Self.lock.lock()
      if Self.pending.removeValue(forKey: key) != nil { Self.insert(image, for: key) }
      Self.lock.unlock()
    }
  }
  func image(_ name: String) throws -> CGImage {
    guard name == URL(fileURLWithPath: name).lastPathComponent, name.hasSuffix(".png") else {
      throw StudioError("Invalid project asset")
    }
    let key = prefix + name
    Self.lock.lock()
    if let image = Self.pending[key] ?? Self.cache[key] {
      if Self.cache[key] != nil {
        Self.order.removeAll { $0 == key }
        Self.order.append(key)
      }
      Self.lock.unlock()
      return image
    }
    Self.lock.unlock()
    // Decode without the lock: other documents and the worker keep rendering meanwhile.
    let url = root.appendingPathComponent(name)
    let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey])
    guard values.isSymbolicLink != true else {
      throw StudioError("Project assets cannot be symbolic links")
    }
    let image = try loadImage(url)
    Self.lock.lock()
    defer { Self.lock.unlock() }
    if let raced = Self.cache[key] { return raced }
    Self.insert(image, for: key)
    return image
  }
  /// Caller holds `lock`.
  private static func insert(_ image: CGImage, for key: String) {
    let cost = image.bytesPerRow * image.height
    guard cost <= Limits.cache, cache[key] == nil else { return }
    while bytes + cost > Limits.cache, let first = order.first {
      order.removeFirst()
      if let removed = cache.removeValue(forKey: first) {
        bytes -= removed.bytesPerRow * removed.height
      }
    }
    cache[key] = image
    order.append(key)
    bytes += cost
  }
  /// Drops this store's images from memory; other open documents keep theirs.
  func purge() {
    Self.lock.lock()
    defer { Self.lock.unlock() }
    let prefix = prefix
    for key in Self.pending.keys where key.hasPrefix(prefix) { Self.pending.removeValue(forKey: key) }
    for key in Self.cache.keys where key.hasPrefix(prefix) {
      if let removed = Self.cache.removeValue(forKey: key) {
        Self.bytes -= removed.bytesPerRow * removed.height
      }
    }
    Self.order.removeAll { $0.hasPrefix(prefix) }
  }
}

func loadImage(_ url: URL, maxSide: Int? = nil) throws -> CGImage {
  guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
    let p = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
    let w = p[kCGImagePropertyPixelWidth] as? Int, let h = p[kCGImagePropertyPixelHeight] as? Int
  else { throw StudioError("This file is not a supported image") }
  if let maxSide {
    guard
      let image = CGImageSourceCreateThumbnailAtIndex(
        source, 0,
        [
          kCGImageSourceCreateThumbnailFromImageAlways: true,
          kCGImageSourceThumbnailMaxPixelSize: maxSide,
          kCGImageSourceCreateThumbnailWithTransform: true,
        ] as CFDictionary)
    else { throw StudioError("Could not resize image") }
    return image
  }
  try Limits.validate(CGSize(width: w, height: h))
  guard
    let image = CGImageSourceCreateThumbnailAtIndex(
      source, 0,
      [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: max(w, h), kCGImageSourceShouldCacheImmediately: true,
      ] as CFDictionary)
  else { throw StudioError("Could not decode image") }
  return image
}

func encode(_ image: CGImage, to url: URL, type: String, quality: CGFloat = 0.9) throws {
  let staging = url.deletingLastPathComponent().appendingPathComponent("." + UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: staging) }
  guard let dest = CGImageDestinationCreateWithURL(staging as CFURL, type as CFString, 1, nil)
  else { throw StudioError("Cannot create export") }
  CGImageDestinationAddImage(
    dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
  guard CGImageDestinationFinalize(dest) else {
    throw StudioError("Export failed. Check available disk space.")
  }
  if FileManager.default.fileExists(atPath: url.path) {
    _ = try FileManager.default.replaceItemAt(url, withItemAt: staging)
  } else {
    try FileManager.default.moveItem(at: staging, to: url)
  }
}

final class StudioDocument {
  let directory: URL
  let store: ImageStore
  var scene: Scene
  var saved = false
  /// Bumped by every committed change, undo and redo (render caches key on it).
  private(set) var revision = 0
  /// Each state keeps its encoded size, so bounding the history never re-encodes it.
  private var undoStates: [(scene: Scene, bytes: Int)] = [], redoStates: [(scene: Scene, bytes: Int)] = []
  private var sceneBytes = 0
  @discardableResult private func persist(_ state: Scene) throws -> Int {
    let data = try JSONEncoder().encode(state)
    guard data.count <= 8_000_000 else {
      throw StudioError(
        "This project has too many edits. Export a flattened image before continuing.")
    }
    try data.write(to: directory.appendingPathComponent("scene.json"), options: .atomic)
    return data.count
  }
  init(image: CGImage, scale: CGFloat = 1, base: URL = SessionStore.root) throws {
    directory = base.appendingPathComponent(UUID().uuidString)
    store = try ImageStore(root: directory.appendingPathComponent("assets"))
    var initialized = false
    let createdDirectory = directory
    let createdStore = store
    defer {
      if !initialized {
        createdStore.waitForWrites()
        try? FileManager.default.removeItem(at: createdDirectory)
        createdStore.purge()
      }
    }
    let asset = try store.add(image)
    let size = CGSize(width: image.width, height: image.height)
    scene = Scene(
      size: size, scale: scale,
      layers: [Layer(asset: asset, rect: CGRect(origin: .zero, size: size))])
    try checkpoint()
    initialized = true
  }
  init(project: URL, recovering: Bool = false) throws {
    let metadata = project.appendingPathComponent("scene.json")
    let info = try metadata.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey])
    guard info.isSymbolicLink != true, (info.fileSize ?? Int.max) <= 8_000_000 else {
      throw StudioError("Invalid or oversized project metadata")
    }
    let data = try Data(contentsOf: project.appendingPathComponent("scene.json"))
    guard data.count <= 8_000_000 else { throw StudioError("Project metadata is too large") }
    scene = try JSONDecoder().decode(Scene.self, from: data)
    try Self.validate(scene)
    directory = recovering ? project : SessionStore.root.appendingPathComponent(UUID().uuidString)
    store = try ImageStore(root: directory.appendingPathComponent("assets"))
    var initialized = false
    defer {
      if !initialized && !recovering { try? FileManager.default.removeItem(at: directory) }
    }
    let input = try ImageStore(root: project.appendingPathComponent("assets"), create: false)
    if !recovering {
      // The validation decodes are cached under the source package; the copy is what gets used.
      defer { input.purge() }
      for name in Set(scene.layers.map(\.asset)) {
        let _ = try input.image(name)
        try FileManager.default.copyItem(
          at: input.root.appendingPathComponent(name), to: store.root.appendingPathComponent(name))
      }
    } else {
      for name in Set(scene.layers.map(\.asset)) { _ = try input.image(name) }
    }
    try checkpoint()
    initialized = true
  }
  static func validate(_ scene: Scene) throws {
    try Limits.validate(scene.size)
    guard scene.version == 1, scene.scale.isFinite, scene.scale > 0, scene.scale <= 8,
      scene.layers.count <= 200, scene.marks.count <= 10_000
    else { throw StudioError("Unsupported or oversized project") }
    let identifiers = scene.layers.map(\.id) + scene.marks.map(\.id)
    guard Set(identifiers).count == identifiers.count else {
      throw StudioError("Project contains duplicate object identifiers")
    }
    func valid(_ rect: CGRect) -> Bool {
      [rect.origin.x, rect.origin.y, rect.width, rect.height].allSatisfy {
        $0.isFinite && abs($0) <= 120_000
      } && rect.width >= 0 && rect.height >= 0
    }
    func point(_ p: CGPoint) -> Bool {
      p.x.isFinite && p.y.isFinite && abs(p.x) <= 120_000 && abs(p.y) <= 120_000
    }
    func ink(_ c: Ink) -> Bool {
      [c.r, c.g, c.b, c.a].allSatisfy { $0.isFinite && (0...1).contains($0) }
    }
    guard
      scene.layers.allSatisfy({
        valid($0.rect) && $0.opacity.isFinite && (0...1).contains($0.opacity)
      }),
      scene.marks.allSatisfy({
        valid($0.rect) && $0.points.count <= 100_000 && $0.width.isFinite
          && (0...500).contains($0.width) && $0.fontSize.isFinite
          && (1...1000).contains($0.fontSize)
          && $0.points.allSatisfy(point) && ($0.end.map(point) ?? true) && ink($0.ink)
          && $0.text.utf8.count <= 100_000
      })
    else { throw StudioError("Invalid project geometry") }
    guard scene.backdrop.padding.isFinite, (0...500).contains(scene.backdrop.padding),
      scene.backdrop.radius.isFinite,
      (0...500).contains(scene.backdrop.radius), ink(scene.backdrop.first),
      ink(scene.backdrop.second)
    else { throw StudioError("Invalid background settings") }
    if scene.backdrop.enabled {
      try Limits.validate(
        CGSize(
          width: scene.size.width + 2 * scene.backdrop.padding,
          height: scene.size.height + 2 * scene.backdrop.padding))
    }
  }
  func change(_ edit: (inout Scene) throws -> Void) throws {
    var next = scene
    try edit(&next)
    try Self.validate(next)
    let nextBytes = try persist(next)
    undoStates.append((scene, sceneBytes))
    if undoStates.count > 100 { undoStates.removeFirst() }
    var historyBytes = 0
    var keep = 0
    for state in undoStates.reversed() {
      historyBytes += state.bytes
      if historyBytes > 32 * 1024 * 1024 { break }
      keep += 1
    }
    if undoStates.count > keep { undoStates.removeFirst(undoStates.count - keep) }
    redoStates.removeAll()
    scene = next
    sceneBytes = nextBytes
    saved = false
    revision += 1
  }
  func undo() throws {
    if let old = undoStates.last {
      try persist(old.scene)
      undoStates.removeLast()
      redoStates.append((scene, sceneBytes))
      (scene, sceneBytes) = old
      saved = false
      revision += 1
    }
  }
  func redo() throws {
    if let next = redoStates.last {
      try persist(next.scene)
      redoStates.removeLast()
      undoStates.append((scene, sceneBytes))
      (scene, sceneBytes) = next
      saved = false
      revision += 1
    }
  }
  func checkpoint() throws {
    sceneBytes = try persist(scene)
  }
  func saveProject(to url: URL) throws {
    try checkpoint()
    try store.flush()
    let fm = FileManager.default
    let staging = url.deletingLastPathComponent().appendingPathComponent("." + UUID().uuidString)
    defer { try? fm.removeItem(at: staging) }
    try fm.createDirectory(
      at: staging.appendingPathComponent("assets"), withIntermediateDirectories: true)
    try fm.copyItem(
      at: directory.appendingPathComponent("scene.json"),
      to: staging.appendingPathComponent("scene.json"))
    for name in Set(scene.layers.map(\.asset)) {
      try fm.copyItem(
        at: store.root.appendingPathComponent(name),
        to: staging.appendingPathComponent("assets").appendingPathComponent(name))
    }
    if fm.fileExists(atPath: url.path) {
      _ = try fm.replaceItemAt(url, withItemAt: staging)
    } else {
      try fm.moveItem(at: staging, to: url)
    }
    saved = true
  }
  func discard() {
    store.waitForWrites()
    try? FileManager.default.removeItem(at: directory)
    store.purge()
  }
}

enum SessionStore {
  /// Variable only so the native tests can keep their sessions out of the user's folder.
  static var root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
    "Library/Application Support/Productivity OS/Screenshot Studio/Sessions")
  static func recoverable() -> [URL] {
    let fm = FileManager.default
    try? fm.createDirectory(
      at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    return
      ((try? fm.contentsOfDirectory(
        at: root, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []).filter {
        let date =
          (try? $0.appendingPathComponent("scene.json").resourceValues(forKeys: [
            .contentModificationDateKey
          ]))?.contentModificationDate ?? .distantPast
        if Date().timeIntervalSince(date) > 86_400 {
          try? fm.removeItem(at: $0)
          return false
        }
        return true
      }
  }
}
