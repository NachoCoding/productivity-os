import { installedAppPath, launchNativeApp, nativeAction, type NativeAppSpec } from "./native-launcher";

export const shelfCommands = ["new", "clipboard", "settings"] as const;
export type ShelfCommand = (typeof shelfCommands)[number];
export const shelfSpec: NativeAppSpec<ShelfCommand> = {
  name: "Drop Shelf",
  bundleId: "com.productivity-os.drop-shelf",
  executable: "DropShelf",
  scheme: "pos-shelf",
  setup: "setup-drop-shelf.sh",
  commands: shelfCommands,
};
export const shelfApp = installedAppPath(shelfSpec);

export function launchShelf(command: ShelfCommand): Promise<void> {
  return launchNativeApp(shelfSpec, command);
}

export function shelfAction(command: ShelfCommand): Promise<void> {
  return nativeAction(shelfSpec, command);
}
