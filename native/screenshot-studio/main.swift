import AppKit

UserDefaults.standard.register(defaults: [
  "delay": 3, "jpegQuality": 0.9, "cursor": false, "shadow": false,
])
if CommandLine.arguments.contains("--version") {
  print("Screenshot Studio 1.0.0")
  exit(0)
}
if CommandLine.arguments.contains("--status") {
  let data: [String: Any] = [
    "version": 1, "screenRecording": CGPreflightScreenCaptureAccess(),
    "accessibility": AXIsProcessTrusted(),
  ]
  print(
    String(
      decoding: try JSONSerialization.data(withJSONObject: data, options: [.sortedKeys]),
      as: UTF8.self))
  exit(0)
}
MainActor.assumeIsolated {
  let app = NSApplication.shared
  app.delegate = StudioApp.shared
  app.run()
}
