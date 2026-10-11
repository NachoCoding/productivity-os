import Foundation
import IOKit
import Darwin

// A one-shot, read-only probe. The privileged policy helper supplies its installed owner UID;
// no GUI session, Accessibility permission, event tap, or resident process is needed.
guard CommandLine.arguments.count == 2, let owner = UInt32(CommandLine.arguments[1]), owner > 0 else {
  fputs("Usage: focus-probe owner-uid\n", stderr)
  exit(64)
}
var bootSize = 0
let bootAvailable = sysctlbyname("kern.bootsessionuuid", nil, &bootSize, nil, 0) == 0 && bootSize > 1 && bootSize < 256
var bootBytes = [CChar](repeating: 0, count: max(1, bootSize))
let bootRead = bootAvailable && sysctlbyname("kern.bootsessionuuid", &bootBytes, &bootSize, nil, 0) == 0
let bootID = bootRead ? String(cString: bootBytes) : "unknown"
let root = IORegistryGetRootEntry(kIOMainPortDefault)
func property(_ name: String) -> Any? {
  guard root != 0 else { return nil }
  return IORegistryEntryCreateCFProperty(root, name as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
}
let locked = property("IOConsoleLocked") as? Bool
let users = property("IOConsoleUsers") as? [[String: Any]]
let ownerOnConsole = users?.contains { user in
  (user["kCGSSessionUserIDKey"] as? NSNumber)?.uint32Value == owner
    && user["kCGSSessionOnConsoleKey"] as? Bool == true
    && user["kCGSessionLoginDoneKey"] as? Bool == true
} ?? false
if root != 0 { IOObjectRelease(root) }
// Time since the last keyboard, pointer, or trackpad input (HIDIdleTime, in nanoseconds). The
// helper's stalled-round safety valve counts only time while the owner is present.
func idleMilliseconds() -> UInt64? {
  let hid = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOHIDSystem"))
  guard hid != 0 else { return nil }
  defer { IOObjectRelease(hid) }
  let value = IORegistryEntryCreateCFProperty(hid, "HIDIdleTime" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
  return (value as? NSNumber).map { $0.uint64Value / 1_000_000 }
}
let available = bootRead && locked != nil && users != nil
var result: [String: Any] = [
  "bootID": bootID,
  "uptimeMs": clock_gettime_nsec_np(CLOCK_UPTIME_RAW) / 1_000_000,
  "wallMs": UInt64(Date().timeIntervalSince1970 * 1_000),
  "available": available,
  "unlocked": available && locked == false && ownerOnConsole,
]
if let idle = idleMilliseconds() { result["idleMs"] = idle }
let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
FileHandle.standardOutput.write(data)
FileHandle.standardOutput.write(Data([10]))
