import AppKit
import Foundation

// A disposable, windowless test app. It never contacts or controls another real application.
final class Fixture: NSObject, NSApplicationDelegate {
    let mode = CommandLine.arguments[1]
    let directory = URL(fileURLWithPath: CommandLine.arguments[2])
    var child: Process?
    var timer: Timer?
    func applicationDidFinishLaunching(_ notification: Notification) {
        if mode == "protected" {
            let process = Process()
            process.executableURL = directory.appendingPathComponent("codex")
            process.arguments = ["120"]
            try! process.run(); child = process
        }
        try! Data(String(getpid()).utf8).write(to: directory.appendingPathComponent("ready"))
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [self] _ in
            if FileManager.default.fileExists(atPath: directory.appendingPathComponent("cleanup").path) {
                if child?.isRunning == true { child?.terminate(); child?.waitUntilExit() }
                exit(0)
            }
        }
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        try! Data("requested".utf8).write(to: directory.appendingPathComponent("quit-request"))
        return mode == "refuse" ? .terminateCancel : .terminateNow
    }
    func applicationWillTerminate(_ notification: Notification) {
        if child?.isRunning == true { child?.terminate(); child?.waitUntilExit() }
    }
}
let application = NSApplication.shared
let delegate = Fixture()
application.delegate = delegate
application.setActivationPolicy(.regular)
application.run()
