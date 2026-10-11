import AppKit
import UniformTypeIdentifiers

private final class IngestObservation: @unchecked Sendable {
  private let lock = NSLock()
  private var storedLate: [URL] = []
  private var storedSettled = 0
  var late: [URL] { lock.lock(); defer { lock.unlock() }; return storedLate }
  var settled: Int { lock.lock(); defer { lock.unlock() }; return storedSettled }
  func recordLate(_ url: URL) { lock.lock(); storedLate.append(url); lock.unlock() }
  func recordSettled() { lock.lock(); storedSettled += 1; lock.unlock() }
}

/// Real receiver API with deterministic source behavior; no general pasteboard or source app.
private final class IngestPromise: NSFilePromiseReceiver {
  struct Delivery {
    let name: String
    var delay: TimeInterval = 0
    var failure = false
    var duplicate = false
  }
  let promisedNames: [String]
  let deliveries: [Delivery]
  var occupiedQueue: DispatchSemaphore?
  private(set) var destination: URL?
  init(names: [String], deliveries: [Delivery]) {
    promisedNames = names; self.deliveries = deliveries
    super.init()
  }
  required init?(pasteboardPropertyList propertyList: Any, ofType type: NSPasteboard.PasteboardType) { return nil }
  override var fileNames: [String] { destination == nil ? [] : promisedNames }
  // Intentionally one type for multiple files, as permitted for legacy promises by AppKit.
  override var fileTypes: [String] { [UTType.png.identifier] }
  override func receivePromisedFiles(atDestination destinationDir: URL, options: [AnyHashable: Any] = [:],
    operationQueue: OperationQueue, reader: @escaping (URL, Error?) -> Void) {
    destination = destinationDir
    if let occupiedQueue { operationQueue.addOperation { occupiedQueue.wait() } }
    for delivery in deliveries {
      DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + delivery.delay) {
        operationQueue.addOperation {
          let url = destinationDir.appendingPathComponent(delivery.name)
          if delivery.failure { reader(url, ShelfError("Fixture source failure")); return }
          do {
            try FileManager.default.createDirectory(at: destinationDir, withIntermediateDirectories: true)
            try Data(delivery.name.utf8).write(to: url)
            reader(url, nil)
            if delivery.duplicate { reader(url, nil) }
          } catch { reader(url, error) }
        }
      }
    }
  }
}

private final class IngestURLProtocol: URLProtocol {
  private static let lock = NSLock()
  private static var fixtureImage = Data()
  static func setImage(_ data: Data) { lock.lock(); fixtureImage = data; lock.unlock() }
  private static func image() -> Data { lock.lock(); defer { lock.unlock() }; return fixtureImage }
  override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "drop-shelf.invalid" }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    guard let url = request.url else { return }
    if url.path == "/hang" { return }
    let html = Data("<html><body>Please sign in</body></html>".utf8)
    let headers: [String: String]
    let data: Data
    switch url.path {
    case "/fake.jpg": headers = ["Content-Type": "image/jpeg"]; data = html
    case "/page.png": headers = ["Content-Type": "text/html"]; data = html
    case "/too-large.png":
      headers = ["Content-Type": "image/png", "Content-Length": String(ShelfStore.maxImageBytes + 1)]
      data = Data()
    case "/empty.png": headers = ["Content-Type": "image/png"]; data = Data()
    default: headers = ["Content-Type": "application/octet-stream"]; data = Self.image()
    }
    let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: data)
    client?.urlProtocolDidFinishLoading(self)
  }
  override func stopLoading() {}
}

@MainActor func runIngestTests(root: URL) async throws {
  let fm = FileManager.default
  let folder = root.appendingPathComponent("ingest-regressions")
  try fm.createDirectory(at: folder, withIntermediateDirectories: true)
  let pixel = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 3, bitsPerSample: 8,
    samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
  let png = pixel.representation(using: .png, properties: [:])!
  let tiff = pixel.tiffRepresentation!
  let board = NSPasteboard(name: .init("drop-shelf-ingest-\(UUID().uuidString)"))
  defer { board.releaseGlobally() }

  check(ShelfIngest.firstImageSource(#"<img data-src="wrong.png" alt="src='also-wrong.png'" src="right.png">"#) == "right.png",
    "HTML image parsing ignores data-src and src text inside other attributes")
  check(ShelfIngest.firstImageSource(#"<IMG SRC='https://example.com/a.png?one=1&amp;two=&#x32;&#51;'>"#)
    == "https://example.com/a.png?one=1&two=23", "HTML image sources decode named and numeric entities")
  check(ShelfIngest.firstImageSource("<img alt='nothing'>") == nil, "HTML without a real image source has no image URL")
  let relative = NSPasteboardItem()
  relative.setString("https://example.com/articles/page", forType: .URL)
  relative.setString("<img src='../images/photo.png'>", forType: .html)
  check(ShelfIngest.imageURL(in: relative)?.absoluteString == "https://example.com/images/photo.png",
    "Browser relative image URLs resolve against the page URL")

  let many = (0..<201).map { index -> NSPasteboardItem in
    let item = NSPasteboardItem(); item.setString("item \(index)", forType: .string); return item
  }
  board.writeObjects(many)
  rejects("Pasteboard item count is rejected before reading image payloads") { _ = try ShelfIngest.entries(from: board) }
  board.clearContents(); board.setData(Data(count: ShelfStore.maxImageBytes + 1), forType: .tiff)
  rejects("Oversized raw TIFF is rejected before image decoding") { _ = try ShelfIngest.entries(from: board) }
  board.setString("https://example.com/original.jpg", forType: .URL)
  let oversizedWithOriginal = try ShelfIngest.entries(from: board)[0]
  check(oversizedWithOriginal.imageData == nil && oversizedWithOriginal.imageURL?.absoluteString == "https://example.com/original.jpg",
    "Oversized browser TIFF pixels do not discard a usable original image URL")
  let futureFile = NSPasteboardItem()
  futureFile.setString(folder.appendingPathComponent("not-yet-delivered.png").absoluteString, forType: .fileURL)
  futureFile.setString("https://example.com/photo.png", forType: .URL)
  futureFile.setData(png, forType: .png)
  board.clearContents(); board.writeObjects([futureFile])
  let future = try ShelfIngest.entries(from: board)[0]
  check(future.file != nil && future.imageURL != nil && future.imageData?.0 == png,
    "Browser file URLs preserve raw pixels and URL fallbacks before the promised path exists")

  check(try ShelfIngest.validatedExtension(png) == "png", "PNG validation inspects the actual image content")
  let normalized = try ShelfIngest.normalized(tiff, extension: "tiff")
  check(try normalized.1 == "png" && ShelfIngest.validatedExtension(normalized.0) == "png",
    "Worker-safe TIFF conversion produces a readable PNG")
  check(try ShelfIngest.normalized(png, extension: "jpg").1 == "png",
    "Actual bytes override an incorrect advertised image format")
  rejects("HTML content cannot masquerade as a PNG") { _ = try ShelfIngest.normalized(Data("<html>Login</html>".utf8), extension: "png") }
  rejects("Truncated image magic bytes cannot masquerade as a readable image") { _ = try ShelfIngest.validatedExtension(Data([0x89, 0x50, 0x4e, 0x47])) }
  let svg = Data(#"<svg xmlns="http://www.w3.org/2000/svg" width="2" height="2"><path d="M0 0L2 2"/></svg>"#.utf8)
  check(try ShelfIngest.validatedExtension(svg) == "svg", "Valid SVG image content is accepted")
  rejects("XML with an unrelated root is not accepted as SVG") { _ = try ShelfIngest.validatedExtension(Data("<html/>".utf8)) }
  rejects("SVG entity declarations are rejected without resolving external resources") {
    _ = try ShelfIngest.validatedExtension(Data(#"<!DOCTYPE svg [<!ENTITY x SYSTEM "file:///etc/passwd">]><svg>&x;</svg>"#.utf8))
  }

  let base64 = URL(string: "data:image/png;base64," + png.base64EncodedString())!
  let decoded = try await ShelfIngest.download(base64)
  check(decoded.0 == png && decoded.1 == "png", "Base64 image URLs preserve original bytes")
  let escaped = png.map { String(format: "%%%02X", $0) }.joined()
  let binary = try await ShelfIngest.download(URL(string: "data:image/png," + escaped)!)
  check(binary.0 == png, "Percent-encoded data images decode binary bytes without UTF-8 corruption")
  board.clearContents(); board.setString(base64.absoluteString, forType: .string)
  check(try ShelfIngest.entries(from: board)[0].text == nil, "Data image URLs cannot fall back to meaningless encoded text")
  check(try ShelfIngest.entries(from: board)[0].payloadBytes == base64.absoluteString.utf8.count,
    "Inline image URLs count their encoded bytes toward the queued payload limit")
  check(ShelfIngest.Entry(imageData: (png, "png"), text: "caption").payloadBytes == png.count + 7,
    "Queued payload accounting includes raw images and accompanying text")
  func rejectsAsync(_ message: String, _ action: () async throws -> Void) async {
    do { try await action(); check(false, message) } catch { print("PASS: \(message)") }
  }
  await rejectsAsync("Invalid declared image data is rejected") {
    _ = try await ShelfIngest.download(URL(string: "data:image/png;base64,SGVsbG8=")!)
  }

  IngestURLProtocol.setImage(png)
  let configuration = URLSessionConfiguration.ephemeral
  configuration.protocolClasses = [IngestURLProtocol.self]
  let session = URLSession(configuration: configuration)
  defer { session.invalidateAndCancel() }
  let downloaded = try await ShelfIngest.download(URL(string: "https://drop-shelf.invalid/no-extension")!, session: session)
  check(downloaded.0 == png && downloaded.1 == "png", "Download recognizes real image bytes with generic MIME and no extension")
  for path in ["/fake.jpg", "/page.png", "/too-large.png", "/empty.png"] {
    await rejectsAsync("Invalid successful HTTP response is rejected: \(path)") {
      _ = try await ShelfIngest.download(URL(string: "https://drop-shelf.invalid\(path)")!, session: session)
    }
  }
  let deadlineStart = Date()
  await rejectsAsync("A stalled HTTP response reaches the absolute deadline") {
    _ = try await ShelfIngest.download(URL(string: "https://drop-shelf.invalid/hang")!, session: session, timeout: 0.05)
  }
  check(Date().timeIntervalSince(deadlineStart) < 2, "HTTP timeout releases the import worker promptly")

  let shared = folder.appendingPathComponent("shared-promises")
  try fm.createDirectory(at: shared, withIntermediateDirectories: true)
  let first = IngestPromise(names: ["first.png", "second.png"], deliveries: [
    .init(name: "second.png", delay: 0.005), .init(name: "first.png", delay: 0.03, duplicate: true),
  ])
  let second = IngestPromise(names: ["third.png"], deliveries: [.init(name: "third.png", delay: 0.01)])
  let observed = IngestObservation()
  let promised = await ShelfIngest.receive([first, second], at: shared, timeout: 1,
    onLateDelivery: { observed.recordLate($0) }, onSettled: { observed.recordSettled() })
  check(first.destination == shared && second.destination == shared, "All promise receivers in one drag share a destination")
  check(try promised[0].get().map(\.lastPathComponent) == ["first.png", "second.png"]
    && promised[1].get().map(\.lastPathComponent) == ["third.png"],
    "Legacy multi-file receivers deliver every file in source order")
  try await Task.sleep(nanoseconds: 30_000_000)
  check(observed.settled == 1 && observed.late.isEmpty, "Promise completion settles once and ignores duplicate successful callbacks")

  let mixed = IngestPromise(names: ["good.png", "bad.png"], deliveries: [
    .init(name: "good.png"), .init(name: "bad.png", delay: 0.01, failure: true),
  ])
  let partial = await ShelfIngest.receive([mixed], at: shared, timeout: 1)
  if case .failure(let error) = partial[0] {
    check((error as? ShelfPromiseFailure)?.files.map(\.lastPathComponent) == ["good.png"],
      "One failed promised file preserves successful siblings from the same receiver")
  } else { check(false, "Mixed promise result reports the failed file") }

  let late = IngestPromise(names: ["late.png"], deliveries: [.init(name: "late.png", delay: 0.12)])
  let lateObserved = IngestObservation()
  let timedOut = await ShelfIngest.receive([late], at: shared, timeout: 0.02,
    onLateDelivery: { url in lateObserved.recordLate(url); try? FileManager.default.removeItem(at: url) },
    onSettled: { lateObserved.recordSettled() })
  if case .failure = timedOut[0] { check(true, "Missing promise callback reaches the deadline") }
  else { check(false, "Missing promise callback reaches the deadline") }
  check(lateObserved.settled == 0, "Timed-out promise keeps its staging lease while the producer is still writing")
  try await Task.sleep(nanoseconds: 200_000_000)
  check(lateObserved.late.count == 1 && lateObserved.settled == 1 && !fm.fileExists(atPath: shared.appendingPathComponent("late.png").path),
    "A late promise is cleaned without resurrecting the item and settles its lease")

  let blocked = IngestPromise(names: ["blocked.png"], deliveries: [.init(name: "blocked.png")])
  let gate = DispatchSemaphore(value: 0)
  blocked.occupiedQueue = gate
  let blockedObserved = IngestObservation()
  let blockedStart = Date()
  let blockedResult = await ShelfIngest.receive([blocked], at: shared, timeout: 0.03,
    onLateDelivery: { blockedObserved.recordLate($0) }, onSettled: { blockedObserved.recordSettled() })
  gate.signal()
  if case .failure = blockedResult[0] { check(true, "A provider occupying its operation queue cannot block the promise deadline") }
  else { check(false, "A provider occupying its operation queue cannot block the promise deadline") }
  check(Date().timeIntervalSince(blockedStart) < 2, "Promise deadline returns before the provider operation is released")
  try await Task.sleep(nanoseconds: 60_000_000)
  check(blockedObserved.settled == 1, "Provider settling after its queue is released completes the staging lease")

  let cancelled = IngestPromise(names: ["cancelled.png"], deliveries: [.init(name: "cancelled.png", delay: 0.08)])
  let cancelledObserved = IngestObservation()
  let task = Task { @MainActor in
    await ShelfIngest.receive([cancelled], at: shared, timeout: 1,
      onLateDelivery: { cancelledObserved.recordLate($0) }, onSettled: { cancelledObserved.recordSettled() })
  }
  try await Task.sleep(nanoseconds: 10_000_000)
  task.cancel()
  let cancelledResult = await task.value
  if case .failure(let error) = cancelledResult[0] {
    check((error as? ShelfPromiseFailure)?.underlying is CancellationError, "Cancellation terminates a pending promise exactly once")
  } else { check(false, "Cancellation terminates a pending promise exactly once") }
  try await Task.sleep(nanoseconds: 120_000_000)
  check(cancelledObserved.late.count == 1 && cancelledObserved.settled == 1,
    "Cancelled promise still cleans late files and releases its staging lease")
}
