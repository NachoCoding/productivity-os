import { launchCommand, LaunchType, showToast, Toast } from "@raycast/api";
import { errorMessage, UnblockOperation } from "./lib";

/** Manifest titles of the commands other commands open (tests keep them in sync with package.json). */
export const COMMAND_TITLES = {
  dashboard: "Productivity OS",
  pomodoro: "Pomodoro",
  "start-pomodoro": "Start Pomodoro",
  "start-focus-session": "Start Focus Session",
  "unlock-request": "Review Unblock Request",
  "blocked-sites": "Blocked Sites",
  "block-preset": "Block Preset",
  "resource-guard": "Resource Guard",
  "screenshot-studio": "Screenshot Studio",
  "clipboard-history": "Clipboard History",
  "drop-shelf": "New Drop Shelf",
  "health-breaks": "Health Break Settings",
  "run-setup": "Run Setup",
} as const;

export type CommandName = keyof typeof COMMAND_TITLES;

/** Opens another command. Raycast refuses a disabled one, so the failure says which command to turn on. */
export async function openCommand(name: CommandName, context?: Record<string, unknown>): Promise<void> {
  try {
    await launchCommand({ name, type: LaunchType.UserInitiated, ...(context ? { context } : {}) });
  } catch (error) {
    await showToast({
      style: Toast.Style.Failure,
      title: `Enable “${COMMAND_TITLES[name]}”`,
      message: `Turn it on in Raycast Settings → Extensions → Productivity OS (${errorMessage(error)}).`,
    });
  }
}

/** Starts the one-minute review in its own command, for callers outside a navigation stack. */
export const openUnblockReview = (operations: UnblockOperation[]) => openCommand("unlock-request", { operations });
