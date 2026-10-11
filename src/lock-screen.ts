import { runAppleScript } from "@raycast/utils";
import { execFile } from "child_process";

// The same call the ⌃⌘Q shortcut makes. It is in a private framework, so if it is ever missing the
// display is put to sleep instead, which locks too when the screen lock delay is immediate.
const LOCK_SCRIPT = `
ObjC.import("Foundation");
$.NSBundle.bundleWithPath("/System/Library/PrivateFrameworks/login.framework").load;
ObjC.bindFunction("SACLockScreenImmediate", ["int", []]);
String($.SACLockScreenImmediate());
`;

export async function lockScreen(): Promise<void> {
  try {
    await runAppleScript(LOCK_SCRIPT, { language: "JavaScript", timeout: 5000 });
  } catch {
    await new Promise<void>((resolve, reject) =>
      execFile("/usr/bin/pmset", ["displaysleepnow"], { timeout: 5000 }, (error) =>
        error ? reject(error) : resolve(),
      ),
    );
  }
}
