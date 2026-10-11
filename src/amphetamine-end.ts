import { showHUD, showToast, Toast } from "@raycast/api";
import { showFailureToast } from "@raycast/utils";
import { endAwakeSession, isSessionActive, requireAmphetamine } from "./amphetamine";

export default async function EndCurrentSession() {
  const toast = await showToast({ style: Toast.Style.Animated, title: "Ending keep awake…" });
  try {
    if (!(await requireAmphetamine(toast))) return;
    if (!(await isSessionActive())) {
      toast.style = Toast.Style.Failure;
      toast.title = "Keep awake is not running";
      return;
    }
    await endAwakeSession();
    await showHUD("😴 Keep awake ended");
  } catch (error) {
    await showFailureToast(error, { title: "Could not end keep awake" });
  }
}
