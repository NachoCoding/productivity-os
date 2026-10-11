import { environment } from "@raycast/api";
import { execFile } from "child_process";
import { existsSync } from "fs";
import { chmod, mkdir, readFile, rename, writeFile } from "fs/promises";
import { join } from "path";

/** `setup` is the first run: the divider is showing, waiting for the user to choose what to keep. */
export type MenuBarState = "hidden" | "visible" | "setup" | "stopped";

// The agent keeps running after the command ends, so it runs from a copy outside the extension's
// assets, which Raycast replaces on every build.
const helperPath = join(environment.supportPath, "menubar-divider");

const run = (command: string) =>
  new Promise<MenuBarState>((resolve, reject) => {
    execFile(helperPath, [command], { timeout: 15000 }, (error, stdout, stderr) => {
      if (error) reject(new Error(stderr.trim() || error.message));
      else resolve(stdout.trim() as MenuBarState);
    });
  });

/** Installs or updates the helper copy, returning the state a replaced agent was in. */
async function installHelper(): Promise<MenuBarState | undefined> {
  const bundled = await readFile(join(environment.assetsPath, "menubar-divider"));
  const installed = await readFile(helperPath).catch(() => undefined);
  if (installed?.equals(bundled)) return undefined;
  const previous = installed ? await run("status").catch(() => undefined) : undefined;
  if (installed) await run("quit").catch(() => undefined);
  await mkdir(environment.supportPath, { recursive: true });
  // Rename into place: overwriting a running executable's file in place gets the process killed.
  await writeFile(`${helperPath}.new`, bundled);
  await chmod(`${helperPath}.new`, 0o755);
  await rename(`${helperPath}.new`, helperPath);
  return previous;
}

/** Hides or shows the menu bar icons left of the divider and returns the resulting state. */
export async function toggleMenuBarIcons(): Promise<MenuBarState> {
  let replaced: MenuBarState | undefined;
  try {
    replaced = await installHelper();
  } catch (error) {
    // An installed copy can still show hidden icons even when the bundled one cannot be read.
    if (!existsSync(helperPath)) throw error;
  }
  // Updating the helper stopped an agent that was hiding icons, which already showed them again.
  if (replaced === "hidden") return "visible";
  return run("toggle");
}

/** The current state, without starting the agent: `stopped` means every icon is showing. */
export async function menuBarIconsState(): Promise<MenuBarState> {
  return run("status").catch(() => "stopped");
}

export function describeMenuBarState(state: MenuBarState): string {
  if (state === "hidden") return "🙈 Menu bar icons hidden";
  if (state === "setup") return "Hold ⌘ and drag the icons to keep to the right of ‹, then toggle again";
  return "👀 Menu bar icons shown";
}
