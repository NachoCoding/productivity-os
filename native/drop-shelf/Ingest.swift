import AppKit
import ImageIO
import UniformTypeIdentifiers

struct ShelfPromiseFailure: LocalizedError {
  let files: [URL]
  let underlying: Error
  var errorDescription: String? { underlying.localizedDescription }
}

/// Snapshots a pasteboard while it is valid; the import coordinator performs expensive work later.
enum ShelfIngest {
  /// Encoded formats that are cheap to snapshot while a drop is in progress, in preference order.
  static let compactImageTypes: [NSPasteboard.PasteboardType] = [
    .png, NSPasteboard.PasteboardType(UTType.jpeg.identifier),
    NSPasteboard.PasteboardType(UTType.heic.identifier), NSPasteboard.PasteboardType(UTType.gif.identifier),
    NSPasteboard.PasteboardType(UTType.webP.identifier),
  ]
  static let imageDataTypes: [NSPasteboard.PasteboardType] = compactImageTypes + [.tiff]
  static let htmlType = NSPasteboard.PasteboardType.html
  static let dragTypes: [NSPasteboard.PasteboardType] = {
    [.fileURL, .URL, .string, htmlType] + imageDataTypes
      + NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }
  }()
  static let dragTypeSet = Set(dragTypes)
  static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "tif", "tiff", "bmp", "avif", "svg", "ico"]
  static let maxImagePixels = 80_000_000

  struct Entry {
    var file: URL?
    var promise: NSFilePromiseReceiver?
    var imageURL: URL?
    var imageData: (Data, String)?
    var text: String?
    var needsAsync: Bool { file == nil && (promise != nil || imageURL != nil || imageData != nil) }
    // A preflight estimate only. Legacy promises may list each type once for several files.
    var promisedCount: Int { promise.map { max(1, $0.fileTypes.count) } ?? 1 }
    var payloadBytes: Int {
      let inlineImage = imageURL?.scheme?.lowercased() == "data" ? imageURL!.absoluteString.utf8.count : 0
      return (imageData?.0.count ?? 0) + (text?.utf8.count ?? 0) + inlineImage
    }
  }

  static func entries(from board: NSPasteboard, preferFileReferences: Bool = false) throws -> [Entry] {
    let items = board.pasteboardItems ?? []
    guard items.count <= ShelfStore.maxItems else { throw ShelfError("Drop no more than 200 items at a time.") }
    let promiseTypes = Set(NSFilePromiseReceiver.readableDraggedTypes)
    let receivers = (board.readObjects(forClasses: [NSFilePromiseReceiver.self]) as? [NSFilePromiseReceiver]) ?? []
    var remaining = receivers[...]
    var capturedBytes = 0
    return try items.map { item in
      var entry = Entry()
      let types = Set(item.types.map(\.rawValue))
      // Consume the matching receiver even if this item also exposes an existing file URL.
      let receiver = types.isDisjoint(with: promiseTypes) ? nil : remaining.popFirst()
      if let raw = item.string(forType: .fileURL), let url = URL(string: raw), url.isFileURL {
        entry.file = url
        // Our own native drag already owns a usable file reference. Keep its lazy pixel
        // provider lazy; external/browser promises still snapshot all fallback formats.
        if preferFileReferences { return entry }
        // Browser promises may advertise their future path before creating it. Keep their
        // other representations so a missing advertised file does not discard the image.
        let fallbackTypes = [NSPasteboard.PasteboardType.URL, htmlType] + imageDataTypes
        if receiver == nil && !fallbackTypes.contains(where: item.types.contains) { return entry }
      }
      entry.imageURL = imageURL(in: item)
      var oversizedPixels = false
      // Pasteboard data has no size until it is transferred, synchronously from the source app.
      // TIFF is usually a huge uncompressed copy of an image that is also offered as a compact
      // encoding, an existing file, a promise, or a URL, so it is read only as the last resort.
      let hasAlternative = receiver != nil || entry.imageURL != nil
        || item.types.contains(where: compactImageTypes.contains)
        || entry.file.map { FileManager.default.fileExists(atPath: $0.path) } == true
      for type in imageDataTypes where item.types.contains(type) && !(type == .tiff && hasAlternative) {
        if let data = item.data(forType: type), !data.isEmpty {
          // Browsers can offer a huge uncompressed TIFF alongside a small original JPEG
          // promise/URL. Ignore that representation and keep trying the usable alternatives.
          if data.count > ShelfStore.maxImageBytes { oversizedPixels = true; continue }
          entry.imageData = (data, fileExtension(for: type))
          break
        }
      }
      if oversizedPixels, entry.imageData == nil, entry.file == nil, receiver == nil, entry.imageURL == nil {
        throw ShelfError("Images are limited to 20 MiB per item.")
      }
      entry.text = item.string(forType: .URL) ?? item.string(forType: .string)
      if entry.imageURL?.scheme?.lowercased() == "data" {
        guard entry.imageURL!.absoluteString.utf8.count <= ShelfStore.maxImageBytes * 4 + 256 else {
          throw ShelfError("Images are limited to 20 MiB per item.")
        }
        // A broken data URL is not useful text and must not become a misleading fallback item.
        entry.text = nil
      } else if let text = entry.text, text.utf8.count > 1_048_576 {
        throw ShelfError("Text must be between 1 byte and 1 MiB.")
      }
      capturedBytes += entry.payloadBytes
      guard capturedBytes <= ShelfStore.maxStoredBytes else { throw ShelfError("This drop contains more than 200 MiB of data.") }
      if let receiver {
        let webLocation = !receiver.fileTypes.isEmpty && receiver.fileTypes.allSatisfy {
          UTType($0)?.conforms(to: .internetLocation) == true
        }
        if !webLocation || entry.imageURL != nil || entry.imageData != nil || entry.text == nil {
          entry.promise = receiver
        }
      }
      return entry
    }
  }

  static func imageURL(in item: NSPasteboardItem) -> URL? {
    if let html = item.string(forType: htmlType), html.utf8.count <= 1_048_576, let src = firstImageSource(html) {
      let base = item.string(forType: .URL).flatMap(URL.init(string:))
      if let url = URL(string: src, relativeTo: base)?.absoluteURL, isFetchable(url) { return url }
    }
    for type in [NSPasteboard.PasteboardType.URL, .string] {
      guard let raw = item.string(forType: type)?.trimmingCharacters(in: .whitespacesAndNewlines),
        !raw.contains(where: \.isWhitespace), let url = URL(string: raw), isFetchable(url)
      else { continue }
      if url.scheme?.lowercased() == "data" && raw.prefix(11).lowercased() == "data:image/" { return url }
      if imageExtensions.contains(url.pathExtension.lowercased()) { return url }
    }
    return nil
  }

  private static let imageTag = try! NSRegularExpression(pattern: #"<img\b((?:[^>"']|"[^"]*"|'[^']*')*)>"#, options: [.caseInsensitive])
  private static let attribute = try! NSRegularExpression(pattern: #"([^\s=/>]+)(?:\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+)))?"#)
  private static let entity = try! NSRegularExpression(pattern: #"&(#(?:[xX][0-9a-fA-F]+|[0-9]+)|amp|quot|apos|lt|gt);"#)

  static func firstImageSource(_ html: String) -> String? {
    guard let tag = imageTag.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
      let tagRange = Range(tag.range(at: 1), in: html) else { return nil }
    let attributes = String(html[tagRange])
    for match in attribute.matches(in: attributes, range: NSRange(attributes.startIndex..., in: attributes)) {
      guard let name = Range(match.range(at: 1), in: attributes), attributes[name].lowercased() == "src" else { continue }
      for group in 2...4 {
        guard let range = Range(match.range(at: group), in: attributes) else { continue }
        var result = String(attributes[range])
        for escaped in entity.matches(in: result, range: NSRange(result.startIndex..., in: result)).reversed() {
          guard let tokenRange = Range(escaped.range(at: 1), in: result), let fullRange = Range(escaped.range, in: result) else { continue }
          let token = String(result[tokenRange])
          let replacement: String?
          if token.hasPrefix("#") {
            let hex = token.lowercased().hasPrefix("#x")
            replacement = UInt32(token.dropFirst(hex ? 2 : 1), radix: hex ? 16 : 10).flatMap(UnicodeScalar.init).map(String.init)
          } else { replacement = ["amp": "&", "quot": "\"", "apos": "'", "lt": "<", "gt": ">"][token] }
          if let replacement { result.replaceSubrange(fullRange, with: replacement) }
        }
        return result.isEmpty ? nil : result
      }
    }
    return nil
  }

  static func isFetchable(_ url: URL) -> Bool {
    let scheme = url.scheme?.lowercased() ?? ""
    return ["http", "https", "data"].contains(scheme) && (scheme == "data" || url.host != nil)
  }
  static func fileExtension(for type: NSPasteboard.PasteboardType) -> String {
    UTType(type.rawValue)?.preferredFilenameExtension ?? "png"
  }
  static func checkImageSize(_ bytes: Int) throws {
    guard bytes > 0 else { throw ShelfError("The image is empty.") }
    guard bytes <= ShelfStore.maxImageBytes else { throw ShelfError("Images are limited to 20 MiB per item.") }
  }

  /// Inspects actual content rather than trusting a server's MIME type or filename.
  /// ImageIO uses a bounded thumbnail to verify raster data without a source-sized allocation.
  static func validatedExtension(_ data: Data) throws -> String {
    try checkImageSize(data.count)
    if let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
      let type = CGImageSourceGetType(source), let uniformType = UTType(type as String),
      uniformType.conforms(to: .image), CGImageSourceGetCount(source) > 0,
      CGImageSourceGetStatus(source) == .statusComplete,
      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
      let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
      let height = properties[kCGImagePropertyPixelHeight] as? NSNumber {
      let pixels = width.doubleValue * height.doubleValue
      guard pixels > 0, pixels <= Double(maxImagePixels) else { throw ShelfError("Images are limited to 80 megapixels.") }
      guard CGImageSourceCreateThumbnailAtIndex(source, 0, [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceThumbnailMaxPixelSize: 16,
        kCGImageSourceShouldCache: false,
      ] as CFDictionary) != nil else { throw ShelfError("The image data is damaged.") }
      return uniformType.preferredFilenameExtension ?? "png"
    }
    if let text = String(data: data, encoding: .utf8),
      !text.localizedCaseInsensitiveContains("<!DOCTYPE"), !text.localizedCaseInsensitiveContains("<!ENTITY") {
      let validator = SVGValidator()
      let parser = XMLParser(data: data)
      parser.shouldProcessNamespaces = true
      parser.shouldResolveExternalEntities = false
      parser.delegate = validator
      if parser.parse(), validator.isSVG { return "svg" }
    }
    throw ShelfError("The dropped content is not a readable image.")
  }

  /// Worker-safe TIFF conversion. Encoded-byte and pixel limits are checked before decoding.
  static func normalized(_ data: Data, extension ext: String) throws -> (Data, String) {
    let actual = try validatedExtension(data)
    guard actual == "tiff" || actual == "tif" else { return (data, actual) }
    guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else {
      throw ShelfError("The image data is damaged.")
    }
    let output = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else {
      throw ShelfError("The image could not be converted to PNG.")
    }
    CGImageDestinationAddImageFromSource(destination, source, 0, nil)
    guard CGImageDestinationFinalize(destination) else { throw ShelfError("The image could not be converted to PNG.") }
    let png = output as Data
    try checkImageSize(png.count)
    return (png, "png")
  }

  static func download(_ url: URL, session: URLSession = .shared, timeout: TimeInterval = 20) async throws -> (Data, String, String) {
    try Task.checkCancellation()
    guard isFetchable(url) else { throw ShelfError("The image URL is not supported.") }
    if url.scheme?.lowercased() == "data" { return try decodeDataURL(url) }
    return try await withThrowingTaskGroup(of: (Data, String, String).self) { group in
      group.addTask { try await fetch(url, session: session, timeout: timeout) }
      group.addTask {
        try await Task.sleep(nanoseconds: UInt64(max(0.001, timeout) * 1_000_000_000))
        throw ShelfError("The image download timed out. Try dropping it again.")
      }
      defer { group.cancelAll() }
      guard let result = try await group.next() else { throw CancellationError() }
      return result
    }
  }

  private static func decodeDataURL(_ url: URL) throws -> (Data, String, String) {
    let raw = url.absoluteString
    guard raw.utf8.count <= ShelfStore.maxImageBytes * 4 + 256,
      let comma = raw.firstIndex(of: ",") else { throw ShelfError("The image data is malformed or too large.") }
    let header = raw[raw.index(raw.startIndex, offsetBy: 5)..<comma].lowercased()
    guard header.hasPrefix("image/") else { throw ShelfError("The dropped data is not an image.") }
    let encoded = Array(raw[raw.index(after: comma)...].utf8)
    var payload = Data()
    payload.reserveCapacity(min(encoded.count, ShelfStore.maxImageBytes))
    var index = 0
    func nibble(_ byte: UInt8) -> UInt8? {
      switch byte { case 48...57: return byte - 48; case 65...70: return byte - 55; case 97...102: return byte - 87; default: return nil }
    }
    while index < encoded.count {
      if encoded[index] == 37 {
        guard index + 2 < encoded.count, let a = nibble(encoded[index + 1]), let b = nibble(encoded[index + 2]) else {
          throw ShelfError("The image data is malformed.")
        }
        payload.append(a * 16 + b); index += 3
      } else { payload.append(encoded[index]); index += 1 }
      guard payload.count <= ShelfStore.maxImageBytes * 4 / 3 + 8 else { throw ShelfError("Images are limited to 20 MiB per item.") }
    }
    let data: Data
    if header.split(separator: ";").contains("base64") {
      guard let decoded = Data(base64Encoded: payload) else { throw ShelfError("The image data is malformed.") }
      data = decoded
    } else { data = payload }
    return (data, try validatedExtension(data), "Image")
  }

  private static func fetch(_ url: URL, session: URLSession, timeout: TimeInterval) async throws -> (Data, String, String) {
    var request = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: timeout)
    request.setValue("image/avif,image/webp,image/png,image/jpeg,image/*;q=0.8", forHTTPHeaderField: "Accept")
    let (bytes, response) = try await session.bytes(for: request)
    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
      throw ShelfError("The image could not be downloaded.")
    }
    if response.expectedContentLength > Int64(ShelfStore.maxImageBytes) { throw ShelfError("Images are limited to 20 MiB per item.") }
    var data = Data()
    data.reserveCapacity(max(0, Int(min(response.expectedContentLength, Int64(ShelfStore.maxImageBytes)))))
    for try await byte in bytes {
      data.append(byte)
      if data.count > ShelfStore.maxImageBytes { throw ShelfError("Images are limited to 20 MiB per item.") }
    }
    try Task.checkCancellation()
    let ext = try validatedExtension(data)
    let name = response.suggestedFilename.flatMap { $0.isEmpty || $0 == "Unknown" ? nil : $0 }
      ?? (url.lastPathComponent.isEmpty || url.lastPathComponent == "/" ? "Image" : url.lastPathComponent)
    return (data, ext, name)
  }

  /// All receivers from one drag must share a destination (AppKit's promise receiver contract).
  /// Results retain receiver order. The caller owns staging and may clean safe late deliveries.
  @MainActor static func receive(_ promises: [NSFilePromiseReceiver], at folder: URL, timeout: TimeInterval = 20,
    onLateDelivery: @escaping @Sendable (URL) -> Void = { _ in },
    onSettled: @escaping @Sendable () -> Void = {}) async -> [Result<[URL], Error>] {
    guard !promises.isEmpty else { onSettled(); return [] }
    let batch = PromiseBatch(count: promises.count, folder: folder, onLateDelivery: onLateDelivery, onSettled: onSettled)
    return await withTaskCancellationHandler(operation: {
      await withCheckedContinuation { continuation in batch.start(promises, timeout: timeout, continuation: continuation) }
    }, onCancel: { batch.cancel() })
  }

  static func isImageFile(_ url: URL) -> Bool {
    (UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) ?? false)
      || imageExtensions.contains(url.pathExtension.lowercased())
  }
}

private final class SVGValidator: NSObject, XMLParserDelegate {
  var isSVG = false
  private var sawRoot = false
  func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String]) {
    guard !sawRoot else { return }
    sawRoot = true
    isSVG = elementName == "svg" && (namespaceURI == nil || namespaceURI == "" || namespaceURI == "http://www.w3.org/2000/svg")
    if !isSVG { parser.abortParsing() }
  }
}

/// Delivery and state use separate queues: a stalled provider cannot hold up the deadline.
/// Registration happens while the state queue is suspended, since fileNames is initially empty.
private final class PromiseBatch: @unchecked Sendable {
  private let queue: OperationQueue = {
    let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1
    queue.qualityOfService = .userInitiated
    return queue
  }()
  private let stateQueue = DispatchQueue(label: "com.productivity-os.drop-shelf.promise-state", qos: .userInitiated)
  private let folder: URL
  private let onLateDelivery: @Sendable (URL) -> Void
  private let onSettled: @Sendable () -> Void
  private var receivers: [NSFilePromiseReceiver] = []
  private var names: [[String]]
  private var expected: [Int]
  private var callbacks: [Int]
  private var seen: [Set<URL>]
  private var expired: [Bool]
  private var files: [[URL]]
  private var failures: [Error?]
  private var results: [Result<[URL], Error>?]
  private var continuation: CheckedContinuation<[Result<[URL], Error>], Never>?
  private var deadline: DispatchWorkItem?
  private var finished = false
  private var settled = false

  init(count: Int, folder: URL, onLateDelivery: @escaping @Sendable (URL) -> Void, onSettled: @escaping @Sendable () -> Void) {
    self.folder = folder; self.onLateDelivery = onLateDelivery; self.onSettled = onSettled
    names = Array(repeating: [], count: count); expected = Array(repeating: 1, count: count)
    callbacks = Array(repeating: 0, count: count); files = Array(repeating: [], count: count)
    seen = Array(repeating: [], count: count); expired = Array(repeating: false, count: count)
    failures = Array(repeating: nil, count: count); results = Array(repeating: nil, count: count)
    stateQueue.suspend()
  }
  @MainActor func start(_ promises: [NSFilePromiseReceiver], timeout: TimeInterval,
    continuation: CheckedContinuation<[Result<[URL], Error>], Never>) {
    self.continuation = continuation; receivers = promises
    for (index, receiver) in promises.enumerated() {
      receiver.receivePromisedFiles(atDestination: folder, options: [:], operationQueue: queue) { [self] url, error in
        stateQueue.async { self.received(index, url: url, error: error) }
      }
      names[index] = receiver.fileNames
      expected[index] = max(1, names[index].count)
    }
    let deadline = DispatchWorkItem { [weak self] in
      self?.finishUnresolved(ShelfError("The source app took too long to provide the file. Try dropping it again."))
    }
    self.deadline = deadline
    stateQueue.asyncAfter(deadline: .now() + max(0.001, timeout), execute: deadline)
    stateQueue.resume()
  }
  func cancel() { stateQueue.async { self.finishUnresolved(CancellationError()) } }
  private func checkedFile(_ url: URL) throws -> URL {
    let root = folder.resolvingSymlinksInPath().standardizedFileURL.path
    guard url.isFileURL, url.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(root + "/") else {
      throw ShelfError("The dropped item arrived outside its staging folder.")
    }
    let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
    guard values.isRegularFile == true, values.isSymbolicLink != true else { throw ShelfError("The dropped item did not arrive as a file.") }
    guard (values.fileSize ?? 0) <= ShelfStore.maxImageBytes else { throw ShelfError("Promised files are limited to 20 MiB per item.") }
    return url
  }
  private func received(_ index: Int, url: URL, error: Error?) {
    // Successful files may receive a duplicate callback, including after the batch returned.
    if error == nil, !seen[index].insert(url).inserted { return }
    if finished || results[index] != nil {
      callbacks[index] += 1
      if expired[index], error == nil, let safe = try? checkedFile(url) { onLateDelivery(safe) }
      settleIfComplete()
      return
    }
    if !receivers[index].fileNames.isEmpty {
      names[index] = receivers[index].fileNames
      expected[index] = max(expected[index], names[index].count)
    }
    callbacks[index] += 1
    do {
      if let error { throw error }
      files[index].append(try checkedFile(url))
    } catch { if failures[index] == nil { failures[index] = error } }
    guard callbacks[index] >= expected[index] else { return }
    if let failure = failures[index] { results[index] = .failure(ShelfPromiseFailure(files: orderedFiles(index), underlying: failure)) }
    else {
      results[index] = .success(orderedFiles(index))
    }
    settleIfComplete()
    if results.allSatisfy({ $0 != nil }) { finish() }
  }
  private func finishUnresolved(_ error: Error) {
    guard !finished else { return }
    for index in results.indices where results[index] == nil {
      results[index] = .failure(ShelfPromiseFailure(files: orderedFiles(index), underlying: error)); expired[index] = true
    }
    finish()
  }
  private func orderedFiles(_ index: Int) -> [URL] {
    let order = names[index]
    return files[index].sorted {
      (order.firstIndex(of: $0.lastPathComponent) ?? Int.max) < (order.firstIndex(of: $1.lastPathComponent) ?? Int.max)
    }
  }
  private func settleIfComplete() {
    guard !settled, callbacks.indices.allSatisfy({ callbacks[$0] >= expected[$0] }) else { return }
    settled = true
    onSettled()
  }
  private func finish() {
    guard !finished else { return }
    finished = true; deadline?.cancel(); deadline = nil
    let continuation = self.continuation; self.continuation = nil
    receivers.removeAll()
    continuation?.resume(returning: results.compactMap { $0 })
  }
}
