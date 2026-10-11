import AppKit

umask(0o077)
if CommandLine.arguments.contains("--version") {
  print("Clipboard History 1.0.0")
} else {
  MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.delegate = ClipboardApp.shared
    app.run()
  }
}
