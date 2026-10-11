import { showHUD, showToast, Toast } from "@raycast/api";
import { writeCache } from "./cached-query";
import { describeColorFilters, toggleColorFilters } from "./color-filters";
import { errorMessage } from "./lib";

export default async function ToggleColorFilters() {
  try {
    const enabled = await toggleColorFilters();
    // The dashboard and the menu bar open with the cached state.
    writeCache("color-filters", enabled);
    await showHUD(describeColorFilters(enabled));
  } catch (error) {
    await showToast({
      style: Toast.Style.Failure,
      title: "Could not toggle color filters",
      message: errorMessage(error),
    });
  }
}
