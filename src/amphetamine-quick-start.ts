import { getPreferenceValues, LaunchProps, showToast, Toast } from "@raycast/api";
import { keepAwake } from "./amphetamine";
import { parseWholeNumber } from "./amphetamine-time";

export default async function QuickStartSession(props: LaunchProps<{ arguments: Arguments.AmphetamineQuickStart }>) {
  const hours = parseWholeNumber(props.arguments.hours);
  const minutes = parseWholeNumber(props.arguments.minutes);
  const seconds = parseWholeNumber(props.arguments.seconds);
  if (hours === null || minutes === null || seconds === null) {
    await showToast({
      style: Toast.Style.Failure,
      title: "Invalid duration",
      message: "Enter whole numbers only, or leave every field empty for no time limit",
    });
    return;
  }
  const totalSeconds = hours * 3600 + minutes * 60 + seconds;
  // Amphetamine counts whole minutes, so leftover seconds round up. Zero means no time limit.
  const { displaySleepAllowed } = getPreferenceValues<Preferences.AmphetamineQuickStart>();
  await keepAwake(Math.ceil(totalSeconds / 60), {
    displaySleepAllowed: !!displaySleepAllowed,
    roundedUp: totalSeconds % 60 !== 0,
  });
}
