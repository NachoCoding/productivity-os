import AppKit

/// Owns accepted drops independently of their windows. Only two resolver jobs run at once;
/// results are committed in acceptance order, in a single transaction for each drop.
@MainActor final class ShelfImportCoordinator {
  struct Resolution {
    var items: [ShelfItem]
    var warning: String? = nil
  }
  private final class PromiseLease {
    var folder: URL?
    var settled = false, finished = false
    init(_ folder: URL) { self.folder = folder }
  }
  private final class Batch {
    let id = UUID(), shelfID: UUID
    let entries: [ShelfIngest.Entry]
    let reserved: Int
    var results: [Result<Resolution, Error>?]
    var staging: URL?
    var lease: PromiseLease?
    var committing = false
    init(shelfID: UUID, entries: [ShelfIngest.Entry]) {
      self.shelfID = shelfID; self.entries = entries
      reserved = entries.reduce(0) { $0 + max(1, $1.promisedCount) }
      results = Array(repeating: nil, count: entries.count)
    }
  }
  private struct Job { let batch: Batch; let indices: [Int]; let promises: Bool }
  unowned let app: DropShelfApp
  /// Deterministic test seam; production always uses the bounded native resolver below.
  var resolver: ((ShelfIngest.Entry) async throws -> Resolution)?
  private var batches: [Batch] = []
  private var jobs: [Job] = []
  private var active = 0
  private var messages: [UUID: String] = [:]
  var isBusy: Bool { !batches.isEmpty || active > 0 }
  /// A shelf-to-shelf drop may outlive the source's native drag session.
  var protectedFileURLs: [URL] { batches.flatMap(\.entries).compactMap(\.file) }
  init(app: DropShelfApp) { self.app = app }
  func pendingCount(for id: UUID) -> Int { batches.filter { $0.shelfID == id }.reduce(0) { $0 + $1.reserved } }
  func message(for id: UUID) -> String? {
    let count = pendingCount(for: id)
    guard count > 0 else { return messages[id] }
    let image = batches.filter { $0.shelfID == id }.flatMap(\.entries).allSatisfy { $0.imageURL != nil || $0.imageData != nil || $0.promise != nil }
    let noun = image ? "image" : "item"
    let progress = count == 1 ? "Adding \(noun)…" : "Adding \(count) \(noun)s…"
    return messages[id].map { progress + " " + $0 } ?? progress
  }

  private func identity(_ entry: ShelfIngest.Entry) -> String? {
    if let file = entry.file { return "file:" + file.standardizedFileURL.path }
    if let url = entry.imageURL { return "image:" + url.absoluteString }
    if entry.promise == nil, entry.imageData == nil, let text = entry.text { return "text:" + text }
    return nil
  }
  func accept(entries: [ShelfIngest.Entry], to id: UUID) throws {
    guard let store = app.store, let shelf = store.shelves.first(where: { $0.id == id }) else { throw ShelfError("Shelf no longer exists.") }
    guard !entries.isEmpty, entries.count <= ShelfStore.maxItems else { throw ShelfError("Drop between 1 and 200 items at a time.") }
    let supported = entries.filter { $0.file != nil || $0.promise != nil || $0.imageURL != nil || $0.imageData != nil || !($0.text ?? "").isEmpty }
    guard !supported.isEmpty else { throw ShelfError("This drop has no supported files, text, links, or images.") }
    var seen = Set(batches.filter { $0.shelfID == id }.flatMap(\.entries).compactMap(identity))
    for item in shelf.items {
      if item.kind == .file { seen.insert("file:" + item.value) }
      if item.kind == .text || item.kind == .link { seen.insert("text:" + item.value) }
    }
    let unique = supported.filter { entry in
      guard let key = identity(entry) else { return true }
      return seen.insert(key).inserted
    }
    guard !unique.isEmpty else { return }
    let batch = Batch(shelfID: id, entries: unique)
    guard shelf.items.count + pendingCount(for: id) + batch.reserved <= ShelfStore.maxItems else { throw ShelfError("A shelf can hold up to 200 items, including items still arriving.") }
    let payloadBytes = unique.reduce(0) { $0 + $1.payloadBytes }
    let waitingBytes = batches.flatMap(\.entries).reduce(0) { $0 + $1.payloadBytes }
    guard payloadBytes + waitingBytes <= ShelfStore.maxStoredBytes else { throw ShelfError("Let the current images finish before adding more.") }
    guard unique.allSatisfy({ ($0.imageData?.0.count ?? 0) <= ShelfStore.maxImageBytes }) else { throw ShelfError("Images are limited to 20 MiB per item.") }
    if pendingCount(for: id) == 0 { messages[id] = nil }
    if supported.count < entries.count { messages[id] = "Some unsupported items were skipped." }
    batches.append(batch); store.protectedShelfIDs.insert(id)
    let promised = unique.indices.filter { unique[$0].promise != nil && resolver == nil }
    if !promised.isEmpty { jobs.append(Job(batch: batch, indices: promised, promises: true)) }
    for index in unique.indices where !promised.contains(index) { jobs.append(Job(batch: batch, indices: [index], promises: false)) }
    refresh(id)
    pump()
  }
  private func refresh(_ id: UUID) {
    app.refreshShelf(id, message: message(for: id))
    app.updateMenu()
  }
  private func pump() {
    while active < 2 && !jobs.isEmpty {
      let job = jobs.removeFirst(); active += 1
      Task { @MainActor in
        if job.promises { await receive(job) }
        else {
          let index = job.indices[0]
          do {
            let result: Resolution
            if let resolver { result = try await resolver(job.batch.entries[index]) }
            else { result = try await resolve(job.batch.entries[index], batch: job.batch) }
            job.batch.results[index] = .success(result)
          } catch { job.batch.results[index] = .failure(error) }
        }
        active -= 1
        drainReadyBatches()
        pump()
      }
    }
  }
  private func staging(for batch: Batch) async throws -> URL {
    if let folder = batch.staging { return folder }
    // Only promise reception creates this folder; ordinary staging uses its own lease below.
    let folder = try await app.withStore { try $0.beginStaging() }
    batch.staging = folder; batch.lease = PromiseLease(folder)
    return folder
  }
  private func receive(_ job: Job) async {
    do {
      let folder = try await staging(for: job.batch)
      let lease = job.batch.lease!
      let promises = job.indices.compactMap { job.batch.entries[$0].promise }
      let results = await ShelfIngest.receive(promises, at: folder, onLateDelivery: { url in
        // The receiver has finished writing this file. Never remove a live producer's folder.
        try? FileManager.default.removeItem(at: url)
      }, onSettled: { [weak self] in
        Task { @MainActor in
          guard let self else { return }
          lease.settled = true
          if lease.finished { await self.releasePromiseFolder(lease) }
        }
      })
      for (offset, index) in job.indices.enumerated() {
        do {
          let urls: [URL]
          var warning: String?
          switch results[offset] {
          case .success(let delivered): urls = delivered
          case .failure(let error):
            guard let partial = error as? ShelfPromiseFailure, !partial.files.isEmpty else { throw error }
            urls = partial.files; warning = partial.localizedDescription
          }
          let sourceWarning = warning
          let resolution = try await app.withStore { store in
            var items: [ShelfItem] = []
            var warnings = sourceWarning.map { [$0] } ?? []
            for url in urls {
              do {
                let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true else { throw ShelfError("The promised file is unavailable.") }
                try store.checkQuota(adding: values.fileSize ?? 0, alreadyStored: true)
                let image = ShelfIngest.isImageFile(url)
                if image { _ = try ShelfIngest.validatedExtension(Data(contentsOf: url, options: .mappedIfSafe)) }
                items.append(try ShelfItem.file(url, owned: true, image: image))
              } catch {
                warnings.append("\(url.lastPathComponent): \(error.localizedDescription)")
                // The promise callback already completed and validated this path inside staging.
                // Do not retain a corrupt sibling merely because another file uses the folder.
                try? FileManager.default.removeItem(at: url)
              }
            }
            guard !items.isEmpty else { throw ShelfError(warnings.first ?? "The promised files are unavailable.") }
            return Resolution(items: items, warning: warnings.isEmpty ? nil : Array(Set(warnings)).sorted().joined(separator: " "))
          }
          job.batch.results[index] = .success(resolution)
        } catch {
          // Promise failure is recoverable while the original pasteboard's fallback data survives.
          jobs.append(Job(batch: job.batch, indices: [index], promises: false))
        }
      }
    } catch {
      for index in job.indices { jobs.append(Job(batch: job.batch, indices: [index], promises: false)) }
    }
  }
  private func saveImage(_ data: Data, ext: String, name: String) async throws -> ShelfItem {
    try await app.withStore { store in
      let (bytes, finalExt) = try ShelfIngest.normalized(data, extension: ext)
      let url = try store.stage(bytes, extension: finalExt, name: name)
      // Protect generated data until the complete batch transaction commits.
      store.pendingDirectories.insert(url.deletingLastPathComponent().standardizedFileURL.path)
      return try ShelfItem.file(url, owned: true, image: true)
    }
  }
  private func resolve(_ entry: ShelfIngest.Entry, batch: Batch) async throws -> Resolution {
    var failure: Error?
    if let file = entry.file {
      do {
        let item = try await Task.detached(priority: .userInitiated) { try ShelfItem.file(file) }.value
        return Resolution(items: [item])
      } catch { failure = error }
    }
    if let (data, ext) = entry.imageData {
      do { return Resolution(items: [try await saveImage(data, ext: ext, name: "Image")]) }
      catch { failure = error }
    }
    if let url = entry.imageURL {
      do {
        let (data, ext, name) = try await ShelfIngest.download(url)
        return Resolution(items: [try await saveImage(data, ext: ext, name: name)])
      } catch { failure = error }
    }
    if let text = entry.text {
      let item = try ShelfItem.text(text)
      let hadImage = entry.imageURL != nil || entry.imageData != nil || entry.promise != nil
      return Resolution(items: [item], warning: hadImage ? "Image unavailable; kept the \(item.kind == .link ? "link" : "text") instead." : nil)
    }
    throw failure ?? ShelfError("The dropped item could not be saved. Try dragging it again.")
  }
  private func drainReadyBatches() {
    for batch in batches {
      // A later drop must never overtake an earlier drop on the same shelf.
      guard !batch.committing,
        batches.first(where: { $0.shelfID == batch.shelfID }) === batch,
        batch.results.allSatisfy({ $0 != nil }) else { continue }
      batch.committing = true
      Task { await commit(batch) }
    }
  }
  private func commit(_ batch: Batch) async {
    var items: [ShelfItem] = [], warnings: [String] = []
    for result in batch.results.compactMap({ $0 }) {
      switch result {
      case .success(let value): items += value.items; if let warning = value.warning { warnings.append(warning) }
      case .failure(let error): warnings.append(error.localizedDescription)
      }
    }
    let ready = items
    do {
      if !ready.isEmpty { try await app.withStore { try $0.add(ready, to: batch.shelfID) } }
    } catch { warnings.append(error.localizedDescription) }
    let folders = ready.filter(\.owned).compactMap { $0.url?.deletingLastPathComponent() }.filter { $0 != batch.staging }
    // Release only this batch's generated folders after commit/rollback; cleanup is serialized.
    _ = try? await app.withStore { store in
      for folder in folders { store.finishStaging(folder) }
    }
    if let lease = batch.lease {
      lease.finished = true
      if lease.settled { await releasePromiseFolder(lease) }
    }
    if !warnings.isEmpty {
      let previous = messages[batch.shelfID].map { [$0] } ?? []
      messages[batch.shelfID] = Array(Set(previous + warnings)).sorted().joined(separator: " ")
    }
    // The sweep is debounced and computes its protected files when it runs, after this batch is gone.
    app.cleanAttachments()
    batches.removeAll { $0 === batch }
    if pendingCount(for: batch.shelfID) == 0 {
      app.store?.protectedShelfIDs.remove(batch.shelfID)
      _ = try? await app.withStore { try $0.trimRecent() }
    }
    refresh(batch.shelfID)
    drainReadyBatches()
  }
  private func releasePromiseFolder(_ lease: PromiseLease) async {
    guard let folder = lease.folder else { return }
    lease.folder = nil
    _ = try? await app.withStore { $0.finishStaging(folder) }
    app.cleanAttachments()
  }
}
