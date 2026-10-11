import { installedAppPath, launchNativeApp, nativeAction, type NativeAppSpec } from "./native-launcher";

export const screenshotCommands = [
  "capture",
  "area",
  "window",
  "display",
  "repeat",
  "delay",
  "scroll",
  "text",
  "record",
  "open",
  "clipboard",
  "settings",
  "unlock-pins",
] as const;
export type ScreenshotCommand = (typeof screenshotCommands)[number];
export const studioSpec: NativeAppSpec<ScreenshotCommand> = {
  name: "Screenshot Studio",
  bundleId: "com.productivity-os.screenshot-studio",
  executable: "ScreenshotStudio",
  scheme: "pos-screenshot",
  setup: "setup-screenshot-studio.sh",
  commands: screenshotCommands,
};
export const studioApp = installedAppPath(studioSpec);

export function launchScreenshot(command: ScreenshotCommand): Promise<void> {
  return launchNativeApp(studioSpec, command);
}

export function screenshotAction(command: ScreenshotCommand): Promise<void> {
  return nativeAction(studioSpec, command);
}
