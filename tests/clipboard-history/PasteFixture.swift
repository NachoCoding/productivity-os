import AppKit

@MainActor final class Fixture: NSObject, NSApplicationDelegate, NSTextViewDelegate {
  var window: NSWindow!
  let root = URL(fileURLWithPath: CommandLine.arguments[1])
  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.regular)
    let main = NSMenu()
    let rootItem = NSMenuItem()
    let edit = NSMenu(title: "Edit")
    edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
    rootItem.submenu = edit
    main.addItem(rootItem)
    NSApp.mainMenu = main
    window = NSWindow(
      contentRect: CGRect(x: 200, y: 200, width: 500, height: 240),
      styleMask: [.titled, .closable], backing: .buffered, defer: false)
    window.title = "Owned Clipboard QA Paste Target"
    window.isReleasedWhenClosed = false
    let text = NSTextView(frame: window.contentView!.bounds)
    text.isRichText = false
    text.delegate = self
    window.contentView = text
    window.makeKeyAndOrderFront(nil)
    window.makeFirstResponder(text)
    NSApp.activate(ignoringOtherApps: true)
    try? Data("ready".utf8).write(to: root.appendingPathComponent("paste-ready"))
  }
  func textDidChange(_ notification: Notification) {
    guard let text = notification.object as? NSTextView,
      text.string == "Clipboard QA: owned fixture\n\tUnicode café 🙂  "
    else { return }
    try? Data("passed".utf8).write(to: root.appendingPathComponent("paste-passed"))
  }
}
@main struct Main {
  @MainActor static func main() {
    _ = NSApplication.shared
    let delegate = Fixture()
    NSApp.delegate = delegate
    NSApp.run()
    withExtendedLifetime(delegate) {}
  }
}
