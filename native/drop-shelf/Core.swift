import AppKit

struct ShelfError: LocalizedError {
  let message: String
  init(_ message: String) { self.message = message }
  var errorDescription: String? { message }
}
struct ShelfItem: Codable, Identifiable, Equatable {
  enum Kind: String, Codable { case file, text, link, image }
  var id = UUID()
  var kind: Kind
  var value: String
  var bookmark: Data?
  var owned = false
  var label: String
  var url: URL? { kind == .file || kind == .image ? URL(fileURLWithPath: value) : nil }
  func resolvedURL() -> URL? {
    guard let url else { return nil }
    if let bookmark {
      var stale = false
      if let resolved = try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting], bookmarkDataIsStale: &stale) { return resolved }
    }
    return url
  }
  static func file(_ url: URL, owned: Bool = false, image: Bool = false) throws -> ShelfItem {
    guard url.isFileURL, FileManager.default.fileExists(atPath: url.path) else { throw ShelfError("The file is no longer available.") }
    return ShelfItem(kind: image ? .image : .file, value: url.standardizedFileURL.path,
      bookmark: owned ? nil : try? url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil),
      owned: owned, label: url.lastPathComponent)
  }
  static func text(_ text: String) throws -> ShelfItem {
    guard !text.isEmpty, text.utf8.count <= 1_048_576 else { throw ShelfError("Text must be between 1 byte and 1 MiB.") }
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    let url = URL(string: trimmed)
    let link = !trimmed.contains(where: { $0.isWhitespace }) && ["http", "https"].contains(url?.scheme?.lowercased() ?? "") && url?.host != nil
    return ShelfItem(kind: link ? .link : .text, value: text, label: String(text.prefix(80)).replacingOccurrences(of: "\n", with: " "))
  }
}
struct Shelf: Codable, Identifiable {
  var id = UUID()
  var name = "Shelf"
  var color = 0
  var pinned = false
  var closed = false
  var updated = Date()
  var items: [ShelfItem] = []
}
/// What a damaged history was replaced with; the files are kept for manual recovery.
struct ShelfStoreRecovery {
  let notice: String
  let keptFiles: [URL]
}
final class ShelfStore {
  static let maxItems = 200
  let root: URL
  private(set) var shelves: [Shelf] = []
  /// Shelves already shown but not yet saved. They stay visible across publishes and are never
  /// copied into worker snapshots, so other transactions cannot save or count them early.
  private(set) var staged: [Shelf] = []
  // Accepted imports retain their destination even after its window closes.
  var protectedShelfIDs = Set<UUID>()
  var stateURL: URL { root.appendingPathComponent("shelves.json") }
  var attachments: URL { root.appendingPathComponent("Items", isDirectory: true) }
  convenience init(root: URL) throws {
    try self.init(prepared: root)
    try load()
  }
  private init(prepared root: URL) throws {
    self.root = root
    try FileManager.default.createDirectory(at: attachments, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
  }
  private func load() throws {
    guard FileManager.default.fileExists(atPath: stateURL.path) else { return }
    let size = try stateURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
    guard size <= 16 * 1_048_576 else { throw ShelfError("Shelf history is too large to load safely.") }
    shelves = try JSONDecoder().decode([Shelf].self, from: Data(contentsOf: stateURL))
    try validate()
  }
  /// Opens history for the app. A history that cannot be loaded is moved aside together with the
  /// saved images it referenced (so no sweep can delete them) and the app starts with an empty history.
  static func open(root: URL, now: Date = Date()) throws -> (store: ShelfStore, recovery: ShelfStoreRecovery?) {
    let store = try ShelfStore(prepared: root)
    do { try store.load(); return (store, nil) } catch {
      let fm = FileManager.default, stamp = Int(now.timeIntervalSince1970)
      func aside(_ name: String) -> URL {
        var candidate = root.appendingPathComponent("\(name).damaged-\(stamp)"), copy = 2
        while fm.fileExists(atPath: candidate.path) { candidate = root.appendingPathComponent("\(name).damaged-\(stamp)-\(copy)"); copy += 1 }
        return candidate
      }
      let items = root.appendingPathComponent("Items", isDirectory: true)
      var kept: [URL] = []
      if let contents = try? fm.contentsOfDirectory(atPath: items.path), !contents.isEmpty {
        let target = aside("Items"); try fm.moveItem(at: items, to: target); kept.append(target)
      }
      let history = aside("shelves.json")
      do { try fm.moveItem(at: store.stateURL, to: history) }
      catch { if let moved = kept.first { try? fm.moveItem(at: moved, to: items) }; throw error }
      kept.insert(history, at: 0)
      let notice = "Shelf history could not be read (\(error.localizedDescription)). Drop Shelf started with an empty history and kept the damaged file as \(history.lastPathComponent)"
        + (kept.count > 1 ? " and its saved images in \(kept[1].lastPathComponent)." : ".")
      return (try ShelfStore(root: root), ShelfStoreRecovery(notice: notice, keptFiles: kept))
    }
  }
  /// A memory-only snapshot for the app's serialized background transactions.
  private init(root: URL, shelves: [Shelf], pending: Set<String>, protected: Set<UUID>) {
    self.root = root; self.shelves = shelves
    pendingDirectories = pending; protectedShelfIDs = protected
  }
  func snapshot() -> ShelfStore {
    let unsaved = Set(staged.map(\.id))
    return ShelfStore(root: root, shelves: shelves.filter { !unsaved.contains($0.id) }, pending: pendingDirectories, protected: protectedShelfIDs)
  }
  func publish(_ snapshot: ShelfStore) {
    let saved = Set(snapshot.shelves.map(\.id))
    staged.removeAll { saved.contains($0.id) }
    shelves = staged + snapshot.shelves
    pendingDirectories = snapshot.pendingDirectories
  }
  /// Shows a new shelf in memory before it is saved; `create(_:)` on the store worker commits it.
  func beginCreate(_ shelf: Shelf) throws {
    let overflow = shelves.count + 1 - 30
    if overflow > 0 {
      let evictable = shelves.filter { $0.closed && !$0.pinned && !protectedShelfIDs.contains($0.id) }.count
      guard evictable >= overflow else { throw ShelfError("Close a shelf before creating another one (30 shelf limit).") }
    }
    staged.insert(shelf, at: 0); shelves.insert(shelf, at: 0)
  }
  /// Withdraws a shown shelf whose save failed.
  func cancelCreate(_ id: UUID) {
    guard staged.contains(where: { $0.id == id }) else { return }
    staged.removeAll { $0.id == id }; shelves.removeAll { $0.id == id }
  }
  func validate() throws {
    guard shelves.count <= 30, Set(shelves.map(\.id)).count == shelves.count,
      shelves.allSatisfy({ shelf in
        (0..<5).contains(shelf.color) && shelf.name.count <= 80
          && shelf.items.count <= Self.maxItems && Set(shelf.items.map(\.id)).count == shelf.items.count
          && shelf.items.allSatisfy { item in
            if item.url != nil { return item.value.hasPrefix("/") }
            return !item.value.isEmpty && item.value.utf8.count <= 1_048_576
          }
      }) else { throw ShelfError("Shelf history contains invalid or oversized entries. The existing file has been preserved.") }
  }
  func save() throws {
    try validate()
    let data = try JSONEncoder().encode(shelves)
    guard data.count <= 16 * 1_048_576 else { throw ShelfError("Shelf history is full. Remove text items from older shelves.") }
    try data.write(to: stateURL, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stateURL.path)
  }
  func transaction(_ change: () throws -> Void) throws {
    let before = shelves
    do { try change(); try save() } catch { shelves = before; throw error }
  }
  @discardableResult func create(_ shelf: Shelf = Shelf()) throws -> UUID {
    try transaction {
      if shelves.count >= 30 {
        guard let index = shelves.indices.filter({ shelves[$0].closed && !shelves[$0].pinned && !protectedShelfIDs.contains(shelves[$0].id) }).min(by: { shelves[$0].updated < shelves[$1].updated }) else {
          throw ShelfError("Close a shelf before creating another one (30 shelf limit).")
        }
        shelves.remove(at: index)
      }
      shelves.insert(shelf, at: 0)
    }
    return shelf.id
  }
  func update(_ id: UUID, _ change: (inout Shelf) throws -> Void) throws {
    guard let index = shelves.firstIndex(where: { $0.id == id }) else { throw ShelfError("Shelf no longer exists.") }
    try transaction { try change(&shelves[index]); shelves[index].updated = Date() }
  }
  func add(_ incoming: [ShelfItem], to id: UUID) throws {
    try update(id) { shelf in
      let unique = incoming.reduce(into: [ShelfItem]()) { result, item in
        if !shelf.items.contains(where: { $0.kind == item.kind && $0.value == item.value })
          && !result.contains(where: { $0.kind == item.kind && $0.value == item.value }) { result.append(item) }
      }
      guard shelf.items.count + unique.count <= Self.maxItems else { throw ShelfError("A shelf can hold up to 200 items.") }
      shelf.items.append(contentsOf: unique)
    }
  }
  func split(_ ids: Set<UUID>, from source: UUID) throws -> UUID {
    guard let index = shelves.firstIndex(where: { $0.id == source }) else { throw ShelfError("Shelf no longer exists.") }
    let moving = shelves[index].items.filter { ids.contains($0.id) }
    guard !moving.isEmpty else { throw ShelfError("Select items to move.") }
    var new = Shelf(); new.items = moving
    try transaction {
      guard shelves.count < 30 else { throw ShelfError("Close a shelf before creating another one (30 shelf limit).") }
      shelves[index].items.removeAll { ids.contains($0.id) }
      shelves[index].updated = Date()
      shelves.insert(new, at: 0)
    }
    return new.id
  }
  func close(_ id: UUID) throws {
    guard let index = shelves.firstIndex(where: { $0.id == id }) else { throw ShelfError("Shelf no longer exists.") }
    try transaction {
      shelves[index].closed = true
      shelves[index].updated = Date()
      let recent = shelves.filter { $0.closed && !$0.pinned && !protectedShelfIDs.contains($0.id) }.sorted { $0.updated > $1.updated }
      let expired = Set(recent.dropFirst(10).map(\.id))
      shelves.removeAll { expired.contains($0.id) }
    }
  }
  func trimRecent() throws {
    let recent = shelves.filter { $0.closed && !$0.pinned && !protectedShelfIDs.contains($0.id) }.sorted { $0.updated > $1.updated }
    let expired = Set(recent.dropFirst(10).map(\.id))
    guard !expired.isEmpty else { return }
    try transaction { shelves.removeAll { expired.contains($0.id) } }
  }
  static let maxImageBytes = 20 * 1_048_576
  static let maxStoredBytes = 200 * 1_048_576
  /// Staging folders still receiving a promised or downloaded file; cleanup must skip them.
  var pendingDirectories = Set<String>()
  func storedBytes() -> Int {
    guard let walk = FileManager.default.enumerator(at: attachments, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else { return 0 }
    var total = 0
    for case let url as URL in walk {
      let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
      if values?.isRegularFile == true { total += values?.fileSize ?? 0 }
    }
    return total
  }
  func checkQuota(adding bytes: Int, alreadyStored: Bool = false) throws {
    guard bytes <= Self.maxImageBytes else { throw ShelfError("Images are limited to 20 MiB per item.") }
    let existing = storedBytes() - (alreadyStored ? bytes : 0)
    guard existing + bytes <= Self.maxStoredBytes else { throw ShelfError("Stored shelf images have reached 200 MiB. Remove unused items first.") }
  }
  /// Writes image bytes into the store. With a name, the file keeps that name inside its own
  /// folder so dragging it out produces a meaningful filename instead of a UUID.
  func stage(_ data: Data, extension ext: String, name: String? = nil) throws -> URL {
    try checkQuota(adding: data.count)
    let url: URL
    if let name, let clean = Self.safeFilename(name, extension: ext) {
      let folder = attachments.appendingPathComponent(UUID().uuidString, isDirectory: true)
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
      url = folder.appendingPathComponent(clean)
    } else {
      url = attachments.appendingPathComponent(UUID().uuidString).appendingPathExtension(ext)
    }
    try data.write(to: url, options: .withoutOverwriting)
    return url
  }
  /// A fresh folder for a file promise; callers must release it with `finishStaging`.
  func beginStaging() throws -> URL {
    let folder = attachments.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    pendingDirectories.insert(folder.standardizedFileURL.path)
    return folder
  }
  func finishStaging(_ folder: URL) { pendingDirectories.remove(folder.standardizedFileURL.path) }
  static func safeFilename(_ raw: String, extension ext: String) -> String? {
    var base = raw.removingPercentEncoding ?? raw
    base = base.components(separatedBy: CharacterSet(charactersIn: "/:\\\0").union(.controlCharacters)).joined(separator: "-")
    base = base.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
    if base.isEmpty { return nil }
    let current = (base as NSString).pathExtension.lowercased()
    let stem = current.isEmpty ? base : (base as NSString).deletingPathExtension
    let wanted = ext.lowercased()
    let same = current == wanted || (["jpg", "jpeg"].contains(current) && ["jpg", "jpeg"].contains(wanted))
    let final = same ? base : stem + "." + wanted
    return String(final.suffix(120))
  }
  func cleanAttachments(protecting urls: [URL] = []) {
    // A drag into another shelf arrives as a normal file URL, not an owned image.
    // Every live reference must retain the backing file, including active exports.
    // Stored paths are already standardized, and only paths inside Items matter here, so no
    // bookmark has to be resolved: a Finder reference can only point into Items by its stored path.
    let referenced = shelves.flatMap(\.items).compactMap { $0.kind == .file || $0.kind == .image ? $0.value : nil }
    let retained = Set(referenced + urls.map { $0.standardizedFileURL.path })
    // Only generated regular files (or generated folders) inside this app's Items directory are eligible.
    for url in (try? FileManager.default.contentsOfDirectory(at: attachments, includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey])) ?? [] {
      guard UUID(uuidString: url.deletingPathExtension().lastPathComponent) != nil,
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey]),
        values.isSymbolicLink != true else { continue }
      let path = url.standardizedFileURL.path
      if values.isDirectory == true {
        guard url.pathExtension.isEmpty, !pendingDirectories.contains(path) else { continue }
        if retained.contains(path) { continue }
        if retained.contains(where: { $0.hasPrefix(path + "/") }) {
          // A promise batch can contain several files. Retaining one must not retain failed
          // or subsequently removed siblings. Never follow symlinks out of our generated folder.
          if let walk = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]) {
            for case let child as URL in walk {
              let attributes = try? child.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
              if attributes?.isSymbolicLink == true { walk.skipDescendants(); continue }
              let childPath = child.standardizedFileURL.path
              let referenced = retained.contains(childPath) || retained.contains(where: { childPath.hasPrefix($0 + "/") })
              if attributes?.isRegularFile == true, !referenced {
                try? FileManager.default.removeItem(at: child)
              }
            }
          }
        } else { try? FileManager.default.removeItem(at: url) }
      } else if values.isRegularFile == true, !retained.contains(path) {
        try? FileManager.default.removeItem(at: url)
      }
    }
  }
}

struct ShelfShakeDetector {
  var last: NSPoint?
  var lastTime: TimeInterval = 0
  var direction = 0, reversals = 0
  var distance: CGFloat = 0
  var cooldown: TimeInterval = 0
  mutating func feed(_ point: NSPoint, time: TimeInterval, dragging: Bool) -> Bool {
    guard dragging, time >= cooldown else { last = nil; reversals = 0; return false }
    guard let previous = last, time - lastTime < 0.45 else {
      last = point; lastTime = time; direction = 0; reversals = 0; distance = 0; return false
    }
    let dx = point.x - previous.x
    guard abs(dx) >= 5 else { return false }
    let next = dx > 0 ? 1 : -1
    distance += abs(dx)
    if direction != 0 && next != direction { reversals += 1 }
    direction = next; last = point; lastTime = time
    if reversals >= 3 && distance >= 110 {
      cooldown = time + 1.5; last = nil; reversals = 0; return true
    }
    return false
  }
}

/// Cancellation shared between the UI and a background copy/ZIP. Cancelling stops the running
/// process (Resource Guard forwards the signal to ditto or drops its queued job).
final class ShelfExportJob: @unchecked Sendable {
  private let lock = NSLock()
  private var cancelled = false
  private var process: Process?
  var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
  func cancel() {
    lock.lock(); cancelled = true; let running = process; lock.unlock()
    if let running, running.isRunning { running.terminate() }
  }
  /// Tracks a launched process; false when the job was cancelled first.
  fileprivate func attach(_ running: Process?) -> Bool {
    lock.lock(); defer { lock.unlock() }
    process = running
    return !cancelled
  }
  func check() throws { if isCancelled { throw ShelfError("The export was cancelled.") } }
}

enum ShelfFiles {
  static let zipTimeout: TimeInterval = 600
  /// Runs a helper process with a deadline and an optional cancellation job; never waits unbounded.
  static func run(_ executable: URL, _ arguments: [String], timeout: TimeInterval, job: ShelfExportJob? = nil) throws {
    try job?.check()
    let process = Process(), exited = DispatchSemaphore(value: 0)
    process.executableURL = executable; process.arguments = arguments
    process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
    process.terminationHandler = { _ in exited.signal() }
    try process.run()
    defer { _ = job?.attach(nil) }
    if job?.attach(process) == false { process.terminate() }
    if exited.wait(timeout: .now() + max(0, timeout)) == .timedOut {
      process.terminate()
      if exited.wait(timeout: .now() + 5) == .timedOut { kill(process.processIdentifier, SIGKILL); _ = exited.wait(timeout: .now() + 2) }
      try job?.check()
      let minutes = Int((timeout / 60).rounded())
      throw ShelfError(minutes >= 1 ? "ZIP creation took longer than \(minutes) minute\(minutes == 1 ? "" : "s") and was stopped. Try fewer or smaller items."
        : "ZIP creation took too long and was stopped. Try fewer or smaller items.")
    }
    try job?.check()
    guard process.terminationStatus == 0 else { throw ShelfError("ZIP creation failed or was cancelled. Check Resource Guard, then try again.") }
  }
  static func availableURL(in folder: URL, name: String) -> URL {
    let safe = URL(fileURLWithPath: name).lastPathComponent
    var result = folder.appendingPathComponent(safe)
    let base = result.deletingPathExtension().lastPathComponent, ext = result.pathExtension
    var n = 2
    while FileManager.default.fileExists(atPath: result.path) {
      result = folder.appendingPathComponent("\(base) \(n)" + (ext.isEmpty ? "" : ".\(ext)")); n += 1
    }
    return result
  }
  static func archive(_ items: [ShelfItem], to folder: URL,
    compress: ((URL, URL) throws -> Void)? = nil, job: ShelfExportJob? = nil, timeout: TimeInterval = zipTimeout) throws -> URL {
    guard !items.isEmpty else { throw ShelfError("The shelf is empty.") }
    try job?.check()
    let fm = FileManager.default
    let staging = fm.temporaryDirectory.appendingPathComponent("drop-shelf-zip-\(UUID().uuidString)")
    try fm.createDirectory(at: staging, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    defer { try? fm.removeItem(at: staging) }
    let contents = staging.appendingPathComponent("Shelf")
    try fm.createDirectory(at: contents, withIntermediateDirectories: true)
    _ = try export(items, to: contents, job: job)
    let archive = staging.appendingPathComponent("Shelf.zip")
    if let compress { try compress(contents, archive) }
    else {
      try run(fm.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/resource-guard"),
        ["run", "--", "/usr/bin/ditto", "-c", "-k", "--keepParent", contents.path, archive.path], timeout: timeout, job: job)
    }
    try job?.check()
    let destination = availableURL(in: folder, name: "Shelf.zip")
    try fm.moveItem(at: archive, to: destination)
    return destination
  }
  static func export(_ items: [ShelfItem], to folder: URL, job: ShelfExportJob? = nil) throws -> [URL] {
    var written: [URL] = []
    for item in items {
      try job?.check()
      if let source = item.resolvedURL() {
        let realSource = source.resolvingSymlinksInPath().standardizedFileURL.path
        let realFolder = folder.resolvingSymlinksInPath().standardizedFileURL.path
        guard realFolder != realSource, !realFolder.hasPrefix(realSource.hasSuffix("/") ? realSource : realSource + "/") else { throw ShelfError("Choose a destination outside the source folder.") }
        let target = availableURL(in: folder, name: source.lastPathComponent)
        try FileManager.default.copyItem(at: source, to: target)
        written.append(target)
      } else {
        let target = availableURL(in: folder, name: item.kind == .link ? "Link.webloc" : "Text.txt")
        let data: Data
        if item.kind == .link {
          data = try PropertyListSerialization.data(fromPropertyList: ["URL": item.value.trimmingCharacters(in: .whitespacesAndNewlines)], format: .xml, options: 0)
        } else { data = Data(item.value.utf8) }
        try data.write(to: target, options: .withoutOverwriting)
        written.append(target)
      }
    }
    return written
  }
}
