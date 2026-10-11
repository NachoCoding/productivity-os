import AppKit
import Vision

struct RecognizedText {
  var text: String
  var rect: CGRect
  var confidence: Float
}

enum VisionTools {
  static func recognize(_ image: CGImage) throws -> [RecognizedText] {
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = false
    request.automaticallyDetectsLanguage = true
    try VNImageRequestHandler(cgImage: image).perform([request])
    return (request.results ?? []).compactMap { observation in
      guard let candidate = observation.topCandidates(1).first else { return nil }
      let r = observation.boundingBox
      return RecognizedText(
        text: candidate.string,
        rect: CGRect(
          x: r.minX * CGFloat(image.width), y: (1 - r.maxY) * CGFloat(image.height),
          width: r.width * CGFloat(image.width), height: r.height * CGFloat(image.height)),
        confidence: candidate.confidence)
    }.sorted {
      abs($0.rect.minY - $1.rect.minY) < 5
        ? $0.rect.minX < $1.rect.minX : $0.rect.minY < $1.rect.minY
    }
  }
  static func barcodes(_ image: CGImage) throws -> [String] {
    let request = VNDetectBarcodesRequest()
    request.symbologies = [.qr]
    try VNImageRequestHandler(cgImage: image).perform([request])
    return (request.results ?? []).compactMap(\.payloadStringValue)
  }
  static let patterns = [
    #"[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#,
    #"\b(?:\d{1,3}\.){3}\d{1,3}\b"#,
    #"\b(?:\d[ -]?){13,19}\b"#,
    #"\b(?:sk-|ghp_|gho_|github_pat_|AKIA|xox[baprs]-)[A-Za-z0-9_-]{8,}"#,
    #"(?i)(?:api[_ -]?key|secret|password|token)\s*[:=]\s*\S+"#,
  ]
  static func sensitive(_ lines: [RecognizedText]) -> [RecognizedText] {
    lines.filter { line in
      patterns.contains {
        line.text.range(of: $0, options: [.regularExpression, .caseInsensitive]) != nil
      }
    }
  }
}

/// A single shared worker: OCR, rendering, stitching and image exports do not run concurrently.
actor ImageWorker {
  static let shared = ImageWorker()
  func run<T: Sendable>(_ work: @Sendable () throws -> T) throws -> T { try work() }
}
