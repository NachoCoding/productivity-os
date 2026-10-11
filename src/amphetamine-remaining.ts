import { showHUD, showToast, Toast } from "@raycast/api";
import { showFailureToast } from "@raycast/utils";
import { requireAmphetamine, tellAmphetamine } from "./amphetamine";
import { describeRemaining } from "./amphetamine-time";

export default async function GetRemainingTime() {
  const toast = await showToast({ style: Toast.Style.Animated, title: "Getting remaining time" });
  try {
    if (!(await requireAmphetamine(toast))) return;
    await showHUD(describeRemaining(await tellAmphetamine("return session time remaining")));
  } catch (error) {
    await showFailureToast(error, { title: "Could not read the remaining time" });
  }
}
