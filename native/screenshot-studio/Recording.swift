import AVFoundation
import AVKit
import AppKit
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

@MainActor
final class RecordingController: NSWindowController, NSWindowDelegate, SCRecordingOutputDelegate,
  SCStreamDelegate
{
  let target: CaptureTarget
  let file: URL
  var stream: SCStream?, output: SCRecordingOutput?, timer: Timer?
  var started: Date?, stopping = false, cancelled = false, finished = false, busy = false,
    saved = false, failed = false
  /// How long a stream that ended by itself waits for its recording output to finalize the file.
  var settleDelay = 2.0
  private var endToken = 0
  var activeExport: AVAssetExportSession?
  let status = label("Ready"), player = AVPlayerView()
  let systemAudio = NSButton(checkboxWithTitle: "System audio", target: nil, action: nil),
    microphone = NSButton(checkboxWithTitle: "Microphone", target: nil, action: nil),
    native = NSButton(checkboxWithTitle: "Native resolution (up to 4K)", target: nil, action: nil)
  var startButton: ClickButton!, stopButton: ClickButton!
  init(target: CaptureTarget) throws {
    self.target = target
    let dir = SessionStore.root.appendingPathComponent("recording-" + UUID().uuidString)
    try FileManager.default.createDirectory(
      at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    file = dir.appendingPathComponent("capture.mp4")
    let window = NSWindow(
      contentRect: CGRect(x: 0, y: 0, width: 650, height: 450),
      styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    window.title = "Short Recording"
    window.isReleasedWhenClosed = false
    window.level = .floating
    super.init(window: window)
    window.delegate = self
    startButton = ClickButton("Record") { [weak self] in self?.start() }
    stopButton = ClickButton("Stop") { [weak self] in self?.stop() }
    stopButton.isEnabled = false
    player.heightAnchor.constraint(greaterThanOrEqualToConstant: 230).isActive = true
    let stack = column([
      row([systemAudio, microphone, native]),
      label(
        "Up to 2 minutes · 30 fps · MP4 · Audio stays off unless selected", size: 11,
        secondary: true), player, status,
      row([startButton, stopButton, ClickButton("Cancel") { [weak self] in self?.cancel() }]),
      row([
        ClickButton("Save MP4") { [weak self] in self?.save() },
        ClickButton("Trim / Mute") { [weak self] in self?.trim() },
        ClickButton("Export GIF") { [weak self] in self?.gif() },
        ClickButton("Extract Frame") { [weak self] in self?.frame() },
      ]),
    ])
    player.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    fill(stack, in: window.contentView!)
    window.center()
  }
  required init?(coder: NSCoder) { fatalError() }
  func start() {
    guard !busy, stream == nil, !finished else { return }
    busy = true
    endToken += 1  // an earlier failure's pending settle must not touch this attempt
    startButton.isEnabled = false
    systemAudio.isEnabled = false
    microphone.isEnabled = false
    native.isEnabled = false
    Task {
      do {
        if microphone.state == .on {
          guard await AVCaptureDevice.requestAccess(for: .audio) else {
            throw StudioError(
              "Microphone access was denied. Disable Microphone or allow access in System Settings."
            )
          }
        }
        for n in (1...3).reversed() {
          guard !cancelled else { throw CancellationError() }
          status.stringValue = "Starting in \(n)…"
          try await Task.sleep(nanoseconds: 1_000_000_000)
        }
        guard !cancelled else { throw CancellationError() }
        let capture = StudioApp.shared.capture
        let content = try await capture.available(onScreenOnly: target.window == nil)
        guard !cancelled else { throw CancellationError() }
        let config = capture.configuration(target)
        let maxSide: Double = native.state == .on ? 3840 : 1920
        let ratio = min(1, maxSide / Double(max(config.width, config.height)))
        config.width = max(2, Int(Double(config.width) * ratio) / 2 * 2)
        config.height = max(2, Int(Double(config.height) * ratio) / 2 * 2)
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        config.queueDepth = 3
        config.capturesAudio = systemAudio.state == .on
        config.captureMicrophone = microphone.state == .on
        config.excludesCurrentProcessAudio = true
        let outputConfig = SCRecordingOutputConfiguration()
        outputConfig.outputURL = file
        outputConfig.outputFileType = .mp4
        outputConfig.videoCodecType = .h264
        let output = SCRecordingOutput(configuration: outputConfig, delegate: self)
        let stream = SCStream(
          filter: capture.filter(target, content: content), configuration: config, delegate: self)
        self.output = output
        self.stream = stream
        try stream.addRecordingOutput(output)
        try await stream.startCapture()
        // A stream that already stopped with an error was handled by `ended`.
        guard self.stream === stream else { return }
        busy = false
        if cancelled {
          stop()
          return
        }
        stopButton.isEnabled = true
        systemAudio.isEnabled = false
        microphone.isEnabled = false
        native.isEnabled = false
      } catch {
        endToken += 1
        busy = false
        stream = nil
        output = nil
        try? FileManager.default.removeItem(at: file)
        startButton.isEnabled = true
        systemAudio.isEnabled = true
        microphone.isEnabled = true
        native.isEnabled = true
        if !cancelled { StudioApp.shared.report(error) } else { window?.close() }
      }
    }
  }
  /// Callbacks from an output this window no longer tracks (failed, settled, replaced) are ignored.
  func isCurrent(_ id: ObjectIdentifier) -> Bool { output.map(ObjectIdentifier.init) == id }
  nonisolated func recordingOutputDidStartRecording(_ recordingOutput: SCRecordingOutput) {
    let id = ObjectIdentifier(recordingOutput)
    Task { @MainActor [self] in
      guard isCurrent(id), stream != nil else { return }
      started = Date()
      status.stringValue = "Recording · 0:00 / 2:00"
      timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
        Task { @MainActor in self?.tick() }
      }
    }
  }
  func tick() {
    guard let started else { return }
    let elapsed = Int(Date().timeIntervalSince(started))
    status.stringValue = String(
      format: "Recording · %d:%02d / 2:00%@", elapsed / 60, elapsed % 60,
      elapsed >= 110 ? " · Finishing soon" : "")
    if elapsed >= 120 { stop() }
  }
  func stop() {
    guard let stream, !stopping else { return }
    stopping = true
    timer?.invalidate()
    timer = nil
    status.stringValue = "Finalizing recording…"
    stopButton.isEnabled = false
    Task {
      do { try await stream.stopCapture() } catch {
        // Never leave a stream that cannot be stopped holding the window, new captures and logout.
        if self.stream === stream { ended(error) }
      }
    }
  }
  nonisolated func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
    let id = ObjectIdentifier(recordingOutput)
    Task { @MainActor in
      guard isCurrent(id), !failed else { return }
      stream = nil
      output = nil
      finished = true
      stopping = false
      busy = false
      timer?.invalidate()
      timer = nil
      if cancelled {
        try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
        window?.close()
        return
      }
      player.player = AVPlayer(url: file)
      status.stringValue = "Ready to trim or save. No permanent copy has been saved."
    }
  }
  nonisolated func recordingOutput(
    _ recordingOutput: SCRecordingOutput, didFailWithError error: Error
  ) {
    let id = ObjectIdentifier(recordingOutput)
    Task { @MainActor in
      guard isCurrent(id) else { return }
      ended(error, outputFailed: true)
      if !cancelled { StudioApp.shared.report(error) }
    }
  }
  nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
    let id = ObjectIdentifier(stream)
    Task { @MainActor in
      guard let current = self.stream, ObjectIdentifier(current) == id else { return }
      ended(error)
    }
  }
  /// The stream stopped by itself (display or window gone, permission revoked, disk full) or could not
  /// be stopped. Reset now so the window can close, new captures start and logout proceeds; keep what
  /// was recorded once the recording output has had `settleDelay` to finalize the file.
  func ended(_ error: Error, outputFailed: Bool = false) {
    guard !finished else { return }
    timer?.invalidate()
    timer = nil
    if let stream { Task { try? await stream.stopCapture() } }
    stream = nil
    stopping = false
    busy = true
    if outputFailed { failed = true }
    stopButton.isEnabled = false
    let reason = error.localizedDescription
    status.stringValue = "Capture ended: \(reason)"
    endToken += 1
    let token = endToken
    DispatchQueue.main.asyncAfter(deadline: .now() + (outputFailed ? 0 : settleDelay)) {
      [weak self] in self?.settle(token, reason: reason)
    }
  }
  func settle(_ token: Int, reason: String) {
    guard token == endToken, !finished, stream == nil else { return }
    busy = false
    output = nil
    if cancelled {
      window?.close()
      return
    }
    let bytes = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
    if started != nil, !failed, bytes > 0 {
      finished = true
      player.player = AVPlayer(url: file)
      status.stringValue =
        "Recording ended early (\(reason)). The captured part is ready to trim or save."
    } else {
      try? FileManager.default.removeItem(at: file)
      started = nil
      failed = false
      for control in [startButton, systemAudio, microphone, native] as [NSButton] {
        control.isEnabled = true
      }
      status.stringValue = "Capture ended: \(reason). Record again or close this window."
    }
  }
  func cancel() {
    cancelled = true
    activeExport?.cancelExport()
    if stream != nil { stop() } else if !busy { window?.close() }
  }
  func save() {
    guard finished, !busy, let url = chooseSave(extension: "mp4") else { return }
    do {
      try copyFile(file, to: url)
      saved = true
      status.stringValue = "Recording saved"
    } catch { StudioApp.shared.report(error) }
  }
  func segment() async throws -> (AVURLAsset, CMTimeRange) {
    let asset = AVURLAsset(url: file)
    let duration = try await asset.load(.duration).seconds
    guard
      let answer = input(
        "Choose segment", message: "Start, end in seconds",
        value: String(format: "0, %.2f", duration))
    else { throw CancellationError() }
    let parts = answer.split(separator: ",").compactMap {
      Double($0.trimmingCharacters(in: .whitespaces))
    }
    guard parts.count == 2, parts.allSatisfy(\.isFinite), parts[0] >= 0, parts[1] > parts[0],
      parts[1] <= duration + 0.05
    else { throw StudioError("Choose a valid time range within the recording") }
    return (
      asset,
      CMTimeRange(
        start: CMTime(seconds: parts[0], preferredTimescale: 600),
        end: CMTime(seconds: min(duration, parts[1]), preferredTimescale: 600))
    )
  }
  func trim() {
    guard finished, !busy else { return }
    busy = true
    Task {
      defer {
        busy = false
        activeExport = nil
        if cancelled { window?.close() }
      }
      do {
        let (asset, range) = try await segment()
        let audioChoice = NSAlert()
        audioChoice.messageText = "Clip audio"
        audioChoice.informativeText = "Keep the recorded sound or export a silent clip."
        ["Keep Audio", "Mute", "Cancel"].forEach { audioChoice.addButton(withTitle: $0) }
        let choice = audioChoice.runModal()
        guard choice != .alertThirdButtonReturn else { return }
        let mute = choice == .alertSecondButtonReturn
        let composition = AVMutableComposition()
        for track in try await asset.loadTracks(withMediaType: .video) {
          guard
            let out = composition.addMutableTrack(
              withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
          else { continue }
          try out.insertTimeRange(range, of: track, at: .zero)
          out.preferredTransform = try await track.load(.preferredTransform)
        }
        if !mute {
          for track in try await asset.loadTracks(withMediaType: .audio) {
            try composition.addMutableTrack(
              withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)?
              .insertTimeRange(range, of: track, at: .zero)
          }
        }
        guard let url = chooseSave(extension: "mp4"),
          let export = AVAssetExportSession(
            asset: composition, presetName: AVAssetExportPresetHighestQuality)
        else { return }
        let temp = file.deletingLastPathComponent().appendingPathComponent(
          UUID().uuidString + ".mp4")
        defer { try? FileManager.default.removeItem(at: temp) }
        status.stringValue = "Exporting clip…"
        activeExport = export
        try await export.export(to: temp, as: .mp4)
        guard !cancelled else { throw CancellationError() }
        try copyFile(temp, to: url)
        saved = true
        status.stringValue = "Clip saved"
      } catch is CancellationError {} catch { if !cancelled { StudioApp.shared.report(error) } }
    }
  }
  func frame() {
    guard finished, !busy else { return }
    busy = true
    let time = player.player?.currentTime() ?? .zero
    Task {
      defer { busy = false }
      do {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: file))
        generator.appliesPreferredTrackTransform = true
        let image = try await generator.image(at: time).image
        try StudioApp.shared.preview(StudioDocument(image: image))
      } catch { StudioApp.shared.report(error) }
    }
  }
  func gif() {
    guard finished, !busy else { return }
    busy = true
    Task {
      defer {
        busy = false
        if cancelled { window?.close() }
      }
      do {
        let (asset, range) = try await segment()
        guard range.duration.seconds <= 15.01 else {
          throw StudioError(
            "GIF segments are limited to 15 seconds. Use MP4 for longer recordings.")
        }
        guard let url = chooseSave(extension: "gif") else { return }
        let count = Int(ceil(range.duration.seconds * 12))
        let temp = file.deletingLastPathComponent().appendingPathComponent(
          UUID().uuidString + ".gif")
        defer { try? FileManager.default.removeItem(at: temp) }
        guard
          let dest = CGImageDestinationCreateWithURL(
            temp as CFURL, UTType.gif.identifier as CFString, count, nil)
        else { throw StudioError("Cannot create GIF") }
        CGImageDestinationSetProperties(
          dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1280, height: 1280)
        for i in 0..<count {
          guard !cancelled else { throw CancellationError() }
          let image = try await generator.image(
            at: CMTimeAdd(range.start, CMTime(seconds: Double(i) / 12, preferredTimescale: 600))
          ).image
          CGImageDestinationAddImage(
            dest, image,
            [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1.0 / 12]]
              as CFDictionary)
          status.stringValue = "GIF: \(i+1) / \(count) frames"
        }
        guard CGImageDestinationFinalize(dest) else { throw StudioError("GIF export failed") }
        try copyFile(temp, to: url)
        saved = true
        status.stringValue = "GIF saved"
      } catch is CancellationError {} catch { StudioApp.shared.report(error) }
    }
  }
  func windowShouldClose(_ sender: NSWindow) -> Bool {
    if stream != nil || busy {
      status.stringValue = "Stop or cancel the active operation first"
      return false
    }
    return cancelled || saved || !finished
      || confirm("Discard recording?", "This recording has not been saved.", action: "Discard")
  }
  func windowWillClose(_ notification: Notification) {
    timer?.invalidate()
    player.player?.pause()
    player.player = nil
    try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
    StudioApp.shared.release(self)
  }
}

func copyFile(_ source: URL, to destination: URL) throws {
  let fm = FileManager.default
  let temp = destination.deletingLastPathComponent().appendingPathComponent("." + UUID().uuidString)
  defer { try? fm.removeItem(at: temp) }
  try fm.copyItem(at: source, to: temp)
  if fm.fileExists(atPath: destination.path) {
    _ = try fm.replaceItemAt(destination, withItemAt: temp)
  } else {
    try fm.moveItem(at: temp, to: destination)
  }
}
