import AppKit

// Menu bar divider for Productivity OS.
//
// Run as `menubar-divider agent`, it owns one status item. Expanding that item as wide as the
// widest display pushes every icon to its left off-screen, which is how those icons are hidden;
// macOS offers no API to hide another app's icon. Hold ⌘ and drag the divider or the icons to
// choose which ones sit to its left; it starts next to Control Center, so every app icon is to its
// left until some are dragged across. Clicking the divider hides or shows them. Any other
// invocation is a client: it sends one command to the running agent (starting it when needed) and
// prints the resulting state.

let portName = "com.productivity-os.menubar" as CFString
let commands: [String: Int32] = ["toggle": 1, "show": 2, "hide": 3, "status": 4, "quit": 5]
let autosaveName = "productivity-os-divider"

final class Divider: NSObject {
    private let item = NSStatusBar.system.statusItem(withLength: 12)
    private var hidden = false { didSet { update() } }

    override init() {
        super.init()
        item.autosaveName = autosaveName
        item.button?.target = self
        item.button?.action = #selector(clicked)
        update()
        NotificationCenter.default.addObserver(
            self, selector: #selector(screensChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    /// The divider's right edge never lies beyond the widest display, so that width pushes everything
    /// on its left off-screen; a fixed 10,000 pt item only cost megabytes of menu bar backing store.
    static func hiddenLength(screenWidths: [CGFloat]) -> CGFloat { screenWidths.max() ?? 10_000 }

    private func update() {
        item.length = hidden ? Self.hiddenLength(screenWidths: NSScreen.screens.map(\.frame.width)) : 12
        guard let button = item.button else { return }
        // While hidden, the chevron stays at the divider's own spot (its right edge), pointing back.
        button.image = NSImage(systemSymbolName: hidden ? "chevron.compact.right" : "chevron.compact.left",
                               accessibilityDescription: hidden ? "Show menu bar icons" : "Hide menu bar icons")
        button.imagePosition = hidden ? .imageTrailing : .imageOnly
        button.imageHugsTitle = false
        button.toolTip = hidden ? "Click to show the hidden icons."
            : "Click to hide the icons to the left. Hold ⌘ and drag to choose which icons are hidden."
    }

    @objc private func clicked() {
        // Clicking the divider is a deliberate choice, so it also completes the first-run introduction.
        UserDefaults.standard.set(true, forKey: "configured")
        hidden.toggle()
    }

    // A wider display may be connected while icons are hidden.
    @objc private func screensChanged() { if hidden { update() } }

    func handle(_ command: Int32) -> String {
        // The first request to hide only introduces the divider, so the user can choose what to keep.
        if (command == 1 || command == 3) && !UserDefaults.standard.bool(forKey: "configured") {
            UserDefaults.standard.set(true, forKey: "configured")
            hidden = false
            return "setup"
        }
        switch command {
        case 1: hidden.toggle()
        case 2: hidden = false
        case 3: hidden = true
        case 5:
            // Quitting removes the divider, so every icon returns.
            DispatchQueue.main.async { exit(0) }
            return "stopped"
        default: break
        }
        return hidden ? "hidden" : "visible"
    }
}

var divider: Divider?

func runAgent() -> Never {
    // Leave the launching command's session so the agent outlives it.
    setsid()
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let callback: CFMessagePortCallBack = { _, command, _, _ in
        Unmanaged.passRetained(Data((divider?.handle(command) ?? "stopped").utf8) as CFData)
    }
    // The port name is unique per login session: a second agent stops here, before it adds a divider.
    guard let port = CFMessagePortCreateLocal(nil, portName, callback, nil, nil) else { exit(1) }
    CFRunLoopAddSource(CFRunLoopGetMain(), CFMessagePortCreateRunLoopSource(nil, port, 0), .commonModes)
    // macOS puts a new item left of every other icon, where a full menu bar (or the notch) can
    // keep it from ever being drawn. Start at the right edge instead, where it can be seen and dragged.
    let position = "NSStatusItem Preferred Position \(autosaveName)"
    if UserDefaults.standard.object(forKey: position) == nil { UserDefaults.standard.set(1, forKey: position) }
    divider = Divider()
    app.run()
    exit(0)
}

enum Reply {
    case state(String)
    case noAgent
    case failed
}

func send(_ command: Int32) -> Reply {
    guard let remote = CFMessagePortCreateRemote(nil, portName) else { return .noAgent }
    var reply: Unmanaged<CFData>?
    let status = CFMessagePortSendRequest(remote, command, nil, 5, 5, CFRunLoopMode.defaultMode.rawValue, &reply)
    guard status == kCFMessagePortSuccess, let data = reply?.takeRetainedValue() else { return .failed }
    return .state(String(decoding: data as Data, as: UTF8.self))
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("\(message)\n".utf8))
    exit(1)
}

let argument = CommandLine.arguments.dropFirst().first ?? ""
if argument == "agent" { runAgent() }
guard let command = commands[argument] else {
    FileHandle.standardError.write(Data("usage: menubar-divider toggle|show|hide|status|quit\n".utf8))
    exit(64)
}
switch send(command) {
case .state(let state):
    print(state)
    exit(0)
case .failed:
    // An agent exists but did not answer. Starting another would add a second divider.
    fail("the menu bar agent is not responding; run `pkill -f 'menubar-divider agent'` to bring every icon back")
case .noAgent:
    break
}
// Without an agent there is no divider, so every icon is already visible.
guard argument == "toggle" || argument == "hide" else {
    print("stopped")
    exit(0)
}
let agent = Process()
agent.executableURL = URL(fileURLWithPath: Bundle.main.executablePath ?? CommandLine.arguments[0])
agent.arguments = ["agent"]
agent.standardInput = FileHandle.nullDevice
agent.standardOutput = FileHandle.nullDevice
agent.standardError = FileHandle.nullDevice
do { try agent.run() } catch { fail("could not start the menu bar agent: \(error.localizedDescription)") }
var started = false
for _ in 0..<200 where !started {
    Thread.sleep(forTimeInterval: 0.05)
    if case .state = send(4) { started = true }
}
guard started else { fail("the menu bar agent did not start") }
// Give macOS a moment to restore the divider's saved position before expanding it.
Thread.sleep(forTimeInterval: 0.3)
guard case .state(let state) = send(3) else { fail("the menu bar agent is not responding") }
print(state)
