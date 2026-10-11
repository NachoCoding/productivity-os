import { LaunchProps, showHUD, showToast, Toast } from "@raycast/api";
import { showFailureToast } from "@raycast/utils";
import { describeAwakeLength, requireAmphetamine, startKeepAwake } from "./amphetamine";
import { parseWholeNumber } from "./amphetamine-time";
import { lockScreen } from "./lock-screen";

/**
 * Locks the screen while the Mac keeps running. Like every keep-awake command, 0 minutes means no
 * time limit and a running session is replaced; this one lets the display sleep. Shows the only HUD,
 * so callers must not add their own. Amphetamine must be installed (callers check).
 */
export async function lockAndKeepAwake(minutes = 0): Promise<string> {
  const replaced = await startKeepAwake(minutes, true);
  const text = `🔒 Locked · awake ${describeAwakeLength(minutes, replaced)}`;
  await showHUD(text);
  await lockScreen();
  return text;
}

export default async function LockKeepAwake(props: LaunchProps<{ arguments: Arguments.LockKeepAwake }>) {
  const minutes = parseWholeNumber(props.arguments.minutes);
  if (minutes === null) {
    await showToast({
      style: Toast.Style.Failure,
      title: "Invalid duration",
      message: "Enter whole minutes, or leave it empty for no time limit",
    });
    return;
  }
  const toast = await showToast({ style: Toast.Style.Animated, title: "Locking…" });
  try {
    if (!(await requireAmphetamine(toast))) return;
    await lockAndKeepAwake(minutes);
  } catch (error) {
    await showFailureToast(error, { title: "Could not lock and keep awake" });
  }
}
