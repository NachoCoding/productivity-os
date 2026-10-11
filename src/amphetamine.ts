import { getApplications, open, showHUD, showToast, Toast } from "@raycast/api";
import { runAppleScript, showFailureToast } from "@raycast/utils";
import { formatShortDuration } from "./amphetamine-time";

// These commands drive the Amphetamine app (https://apps.apple.com/app/amphetamine/id937984704)
// through its AppleScript dictionary, mirroring the Raycast "Amphetamine" extension by gstvds.
export const AMPHETAMINE_URL = "https://apps.apple.com/app/amphetamine/id937984704";
const BUNDLE_ID = "com.if.Amphetamine";

export const tellAmphetamine = (statement: string) =>
  runAppleScript(`tell application "Amphetamine"\n${statement}\nend tell`);

export async function amphetamineInstalled(): Promise<boolean> {
  return (await getApplications()).some((app) => app.bundleId === BUNDLE_ID);
}

/** Turns `toast` into a failure with a download action and returns false when Amphetamine is missing. */
export async function requireAmphetamine(toast: Toast): Promise<boolean> {
  if (await amphetamineInstalled()) return true;
  toast.style = Toast.Style.Failure;
  toast.title = "Amphetamine is not installed";
  toast.message = "Press ⌘D to download";
  toast.primaryAction = {
    title: "Download",
    shortcut: { modifiers: ["cmd"], key: "d" },
    onAction: () => open(AMPHETAMINE_URL),
  };
  return false;
}

export async function isSessionActive(): Promise<boolean> {
  return (await tellAmphetamine("return session is active")) === "true";
}

/**
 * The one rule every keep-awake command follows: `minutes` of 0 (an empty field) means no time limit,
 * and a new session replaces the running one. Resolves to whether a session was replaced.
 */
export async function startKeepAwake(minutes: number, displaySleepAllowed = false): Promise<boolean> {
  const interval = minutes === 0 ? 0 : "minutes";
  const answer = await tellAmphetamine(
    `set wasActive to session is active
start new session with options {duration:${minutes}, interval:${interval}, displaySleepAllowed:${displaySleepAllowed}}
return wasActive`,
  );
  return answer.trim() === "true";
}

/** "for 1h 30m" or "with no time limit", plus a note when a running session was replaced. */
export function describeAwakeLength(minutes: number, replaced: boolean, roundedUp = false): string {
  const length = minutes === 0 ? "with no time limit" : `for ${formatShortDuration(minutes)}`;
  return `${length}${roundedUp ? " (rounded up)" : ""}${replaced ? " · replaced the running session" : ""}`;
}

/** The HUD text for a keep-awake session started by {@link startKeepAwake}. */
export const describeKeepAwake = (minutes: number, replaced: boolean, roundedUp = false) =>
  `☕ Keeping awake ${describeAwakeLength(minutes, replaced, roundedUp)}`;

/** Shared by the keep-awake commands: checks for Amphetamine, starts the session, shows one HUD. */
export async function keepAwake(
  minutes: number,
  options: { displaySleepAllowed?: boolean; roundedUp?: boolean } = {},
): Promise<boolean> {
  const toast = await showToast({ style: Toast.Style.Animated, title: "Starting keep awake…" });
  try {
    if (!(await requireAmphetamine(toast))) return false;
    const replaced = await startKeepAwake(minutes, options.displaySleepAllowed);
    await showHUD(describeKeepAwake(minutes, replaced, options.roundedUp));
    return true;
  } catch (error) {
    await showFailureToast(error, { title: "Could not start keep awake" });
    return false;
  }
}

/**
 * Start Keep Awake has no duration to give, so Amphetamine's own default session decides the length, and a
 * session that is already running is left alone (commands with a duration replace it instead).
 */
export async function startDefaultKeepAwake(): Promise<boolean> {
  const toast = await showToast({ style: Toast.Style.Animated, title: "Starting keep awake…" });
  try {
    if (!(await requireAmphetamine(toast))) return false;
    const answer = await tellAmphetamine(`if session is active then return "running"
start new session
return "started"`);
    await showHUD(answer.trim() === "running" ? "☕ Keep awake is already running" : "☕ Keep awake started");
    return true;
  } catch (error) {
    await showFailureToast(error, { title: "Could not start keep awake" });
    return false;
  }
}

export const endAwakeSession = () => tellAmphetamine("end session");

/** `remaining` is Amphetamine's `session time remaining` answer: seconds, or 0, -1 or -2 for untimed sessions. */
export type AwakeStatus = { state: "missing" | "stopped" | "idle" } | { state: "active"; remaining: number };

/** Reads the session state without launching Amphetamine when it is not running. */
export async function awakeStatus(): Promise<AwakeStatus> {
  if (!(await amphetamineInstalled())) return { state: "missing" };
  const answer = await runAppleScript(`
    if application "Amphetamine" is not running then return "stopped"
    tell application "Amphetamine"
      if not (session is active) then return "idle"
      return (session time remaining) as text
    end tell`);
  if (answer === "stopped" || answer === "idle") return { state: answer };
  return { state: "active", remaining: Number(answer) };
}
