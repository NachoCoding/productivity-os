import { showHUD, showToast, Toast } from "@raycast/api";
import { writeCache } from "./cached-query";
import { errorMessage } from "./lib";
import { describeMenuBarState, toggleMenuBarIcons } from "./menu-bar-icons";

export default async function ToggleMenuBarIcons() {
  try {
    const state = await toggleMenuBarIcons();
    // The dashboard and the menu bar open with the cached state.
    writeCache("menu-bar-icons", state);
    await showHUD(describeMenuBarState(state));
  } catch (error) {
    await showToast({
      style: Toast.Style.Failure,
      title: "Could not toggle menu bar icons",
      message: errorMessage(error),
    });
  }
}
