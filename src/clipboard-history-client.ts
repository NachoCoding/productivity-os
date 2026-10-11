import { installedAppPath, launchNativeApp, nativeAction, type NativeAppSpec } from "./native-launcher";

export const clipboardCommands = ["history", "settings"] as const;
export type ClipboardCommand = (typeof clipboardCommands)[number];
export const clipboardSpec: NativeAppSpec<ClipboardCommand> = {
  name: "Clipboard History",
  bundleId: "com.productivity-os.clipboard-history",
  executable: "ClipboardHistory",
  scheme: "pos-clipboard",
  setup: "setup-clipboard-history.sh",
  commands: clipboardCommands,
};
export const clipboardApp = installedAppPath(clipboardSpec);

export function launchClipboard(command: ClipboardCommand): Promise<void> {
  return launchNativeApp(clipboardSpec, command);
}

export function clipboardAction(command: ClipboardCommand): Promise<void> {
  return nativeAction(clipboardSpec, command);
}
