import AppKit
umask(0o077)
if CommandLine.arguments.contains("--version") { print("Drop Shelf 1.0.0") }
else {
  MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.delegate = DropShelfApp.shared
    app.run()
  }
}
