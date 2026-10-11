import { closeMainWindow, environment, showHUD, showToast, Toast } from "@raycast/api";
import { execFile } from "child_process";
import { access, readFile } from "fs/promises";
import { homedir } from "os";
import { join } from "path";
import { setTimeout as delay } from "timers/promises";
import { promisify } from "util";

const execute = promisify(execFile);

/** A native helper bundled in the extension's assets and installed to ~/Applications by its setup script. */
export interface NativeAppSpec<Command extends string = string> {
  /** Bundle name without ".app", also used in messages. */
  name: string;
  /** CFBundleIdentifier; also the LaunchAgent label. */
  bundleId: string;
  /** Executable in Contents/MacOS. */
  executable: string;
  /** URL scheme the app handles. */
  scheme: string;
  /** Setup script in the extension's assets (install | update | uninstall). */
  setup: string;
  /** The only commands that may be sent. */
  commands: readonly Command[];
  /** Commands delivered without activating the app (`open -g`). */
  background?: readonly Command[];
  /** Extra bundle files byte-compared when either copy lacks a POSBuildID. */
  compare?: readonly string[];
}

export type InstallState = "current" | "outdated" | "missing";

/** Setup exit status when the running helper would not quit; nothing was replaced. */
export const SETUP_BUSY = 75;

export function installedAppPath(spec: Pick<NativeAppSpec, "name">): string {
  return join(homedir(), "Applications", `${spec.name}.app`);
}

/** The build fingerprint stamped into Info.plist by assets/build-*.sh. */
export function buildID(infoPlist: Buffer | string | undefined): string | undefined {
  return /<key>POSBuildID<\/key>\s*<string>([^<]+)<\/string>/.exec(String(infoPlist ?? ""))?.[1].trim() || undefined;
}

export async function installState(spec: NativeAppSpec): Promise<InstallState> {
  const bundled = join(environment.assetsPath, `${spec.name}.app`);
  const installed = installedAppPath(spec);
  const executable = `Contents/MacOS/${spec.executable}`;
  const [installedInfo, hasExecutable] = await Promise.all([
    readFile(join(installed, "Contents/Info.plist")).catch(() => undefined),
    access(join(installed, executable)).then(
      () => true,
      () => false,
    ),
  ]);
  if (!installedInfo || !hasExecutable) return "missing";
  // An unreadable bundled copy (not built, or mid-rebuild) never blocks the installed one.
  const bundledInfo = await readFile(join(bundled, "Contents/Info.plist")).catch(() => undefined);
  if (!bundledInfo) return "current";
  const [wanted, present] = [buildID(bundledInfo), buildID(installedInfo)];
  if (wanted && present) return wanted === present ? "current" : "outdated";
  if (!bundledInfo.equals(installedInfo)) return "outdated";
  for (const file of [executable, ...(spec.compare ?? [])]) {
    const [next, current] = await Promise.all([
      readFile(join(bundled, file)).catch(() => undefined),
      readFile(join(installed, file)).catch(() => undefined),
    ]);
    if (next && !current?.equals(next)) return "outdated";
  }
  return "current";
}

function exitStatus(error: unknown): number | undefined {
  const code = (error as { code?: unknown } | undefined)?.code;
  return typeof code === "number" ? code : undefined;
}

/** The last line a failed tool printed on stderr, else the error message. */
export function errorMessage(error: unknown): string {
  const { stderr, message } = (typeof error === "object" && error ? error : {}) as {
    stderr?: unknown;
    message?: unknown;
  };
  const detail = typeof stderr === "string" ? stderr.trim().split("\n").pop()?.trim() : undefined;
  return detail || (typeof message === "string" ? message : String(error));
}

async function isRunning(spec: NativeAppSpec): Promise<boolean> {
  const { stdout } = await execute("/usr/bin/lsappinfo", ["find", `bundleid=${spec.bundleId}`], { timeout: 2000 });
  return stdout.trim() !== "";
}

/**
 * Starts a loaded but stopped LaunchAgent and waits briefly for it, so the URL reaches the supervised copy
 * instead of racing a second launch (the duplicate quits and drops the URL). Any failure leaves `open -a` to it.
 */
async function wakeAgent(spec: NativeAppSpec): Promise<void> {
  try {
    const uid = process.getuid?.();
    if (uid === undefined || (await isRunning(spec))) return;
    const service = `gui/${uid}/${spec.bundleId}`;
    await execute("/bin/launchctl", ["print", service], { timeout: 2000 });
    await execute("/bin/launchctl", ["kickstart", service], { timeout: 3000 });
    for (let poll = 0; poll < 30; poll++) {
      await delay(100);
      if (await isRunning(spec)) return;
    }
  } catch {
    // Not loaded, or launchd/LaunchServices failed.
  }
}

/**
 * Installs the helper if needed, updates it when the bundled build differs (never failing the command when the
 * running copy is busy), then delivers `<scheme>://<command>` to the installed copy.
 */
export async function launchNativeApp<Command extends string>(
  spec: NativeAppSpec<Command>,
  command: Command,
): Promise<void> {
  if (!spec.commands.includes(command)) throw new Error(`Unsupported ${spec.name} command`);
  let notice: string | undefined;
  const state = await installState(spec);
  if (state !== "current") {
    const installing = state === "missing";
    const toast = await showToast({
      style: Toast.Style.Animated,
      title: `${installing ? "Installing" : "Updating"} ${spec.name}…`,
    });
    try {
      await execute("/bin/bash", [join(environment.assetsPath, spec.setup), installing ? "install" : "update"], {
        timeout: 30000,
      });
    } catch (error) {
      // Without an installed copy there is nothing to open; a failed update keeps the installed one working.
      if (installing) throw error;
      notice =
        exitStatus(error) === SETUP_BUSY
          ? `Quit ${spec.name} to finish updating`
          : `${spec.name} update failed; using the installed version`;
    }
    await toast.hide();
  }
  await closeMainWindow();
  await wakeAgent(spec);
  const background = spec.background?.includes(command) ? ["-g"] : [];
  await execute("/usr/bin/open", [...background, "-a", installedAppPath(spec), `${spec.scheme}://${command}`], {
    timeout: 10000,
  });
  if (notice) await showHUD(notice);
}

export async function nativeAction<Command extends string>(
  spec: NativeAppSpec<Command>,
  command: Command,
): Promise<void> {
  try {
    await launchNativeApp(spec, command);
  } catch (error) {
    await showToast({ style: Toast.Style.Failure, title: `${spec.name} could not open`, message: errorMessage(error) });
  }
}
