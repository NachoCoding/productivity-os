import { LaunchProps, showHUD, showToast, Toast } from "@raycast/api";
import { forgetSetup, setupDone, updateCachedStatus } from "./blocker-state";
import { openCommand } from "./launch";
import {
  errorMessage,
  formatClock,
  getBlocked,
  MAX_FOCUS_MINUTES,
  needsSetup,
  parseFocusMinutes,
  startFocusSession,
  withFocusSession,
} from "./lib";
import { getPreset } from "./presets";

const fail = (title: string, message?: string) => showToast({ style: Toast.Style.Failure, title, message });

/** Starts a focus session straight from the search bar: a preset (or the blocked sites) and minutes. */
export default async function QuickFocus(props: LaunchProps<{ arguments: Arguments.QuickFocus }>) {
  const minutes = parseFocusMinutes(props.arguments.minutes?.trim() || "30");
  if (minutes === undefined) {
    await fail("Invalid duration", `Enter a whole number of minutes between 1 and ${MAX_FOCUS_MINUTES}`);
    return;
  }
  try {
    // The verdict is cached; a stale one is caught below when the helper refuses to run.
    if (!(await setupDone())) {
      await openCommand("run-setup");
      return;
    }
    // "custom" means the sites that are blocked right now, as in the Start Focus Session form.
    const preset = getPreset(props.arguments.preset || "social");
    const domains = preset ? preset.domains : (await getBlocked()).map((entry) => entry.domain);
    if (domains.length === 0) {
      await fail("Nothing is currently blocked", "Pick a preset instead");
      return;
    }
    const label = preset ? preset.title : "Custom";
    const session = await startFocusSession(minutes, `${label} focus`, domains);
    updateCachedStatus((status) => withFocusSession(status, session, domains));
    await showHUD(`🔒 Focus until ${formatClock(session.endsAt)} (${label}, ${minutes} min)`);
  } catch (error) {
    if (needsSetup(error)) {
      forgetSetup();
      await openCommand("run-setup");
      return;
    }
    await fail("Could not start session", errorMessage(error));
  }
}
