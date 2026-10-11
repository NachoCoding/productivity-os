import { clipboardAction } from "./clipboard-history-client";
export default async function Command() {
  await clipboardAction("settings");
}
