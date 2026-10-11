import { installedAppPath, launchNativeApp, nativeAction, type NativeAppSpec } from "./native-launcher";

export const healthCommands = [
  "settings",
  "break",
  "preview",
  "pomodoro",
  "pomodoro-start",
  "pomodoro-settings",
  "posture",
] as const;
export type HealthCommand = (typeof healthCommands)[number];
export const healthSpec: NativeAppSpec<HealthCommand> = {
  name: "Health Breaks",
  bundleId: "com.productivity-os.health-breaks",
  executable: "HealthBreaks",
  scheme: "pos-health",
  setup: "setup-health-breaks.sh",
  commands: healthCommands,
  // Reminders and the silent Pomodoro start must not steal focus.
  background: ["pomodoro-start", "break", "preview"],
  compare: ["Contents/Resources/pomodoro-presets.json"],
};
export const healthApp = installedAppPath(healthSpec);

export function launchHealth(command: HealthCommand): Promise<void> {
  return launchNativeApp(healthSpec, command);
}

export function healthAction(command: HealthCommand): Promise<void> {
  return nativeAction(healthSpec, command);
}
