import {
  Action,
  ActionPanel,
  Clipboard,
  Detail,
  environment,
  Icon,
  Keyboard,
  open,
  showHUD,
  showToast,
  Toast,
  useNavigation,
} from "@raycast/api";
import { readFile } from "fs/promises";
import { join } from "path";
import { useState } from "react";
import { verifySetup } from "./blocker-state";
import { errorMessage, HELPER_PATH } from "./lib";

const quote = (value: string) => "'" + value.replace(/'/g, "'\\''") + "'";
export const SETUP_COMMAND = `sudo /bin/bash ${quote(join(environment.assetsPath, "setup.sh"))}`;
const INSTALLED_PROBE = "/Library/PrivilegedHelperTools/productivity-os/focus-probe";

/** True when an installed root helper (the blocker or its focus probe) differs from the bundled copy. */
export async function helperNeedsUpdate(): Promise<boolean> {
  const differs = async (installed: string, bundled: string) => {
    const [current, shipped] = await Promise.all([
      readFile(installed).catch(() => undefined),
      readFile(bundled).catch(() => undefined),
    ]);
    return !!shipped && !current?.equals(shipped);
  };
  const results = await Promise.all([
    differs(HELPER_PATH, join(environment.assetsPath, "blocker.sh")),
    differs(INSTALLED_PROBE, join(environment.assetsPath, "focus-probe")),
  ]);
  return results.some(Boolean);
}

const markdown = `## Productivity OS setup

Run this command in Terminal to install or update Productivity OS. It asks for your Mac password:

\`\`\`sh
${SETUP_COMMAND}
\`\`\`

Then choose **Check Again**.

The installer updates the root-owned blocker and focus clock, grants your account passwordless access to their limited commands, and keeps website protection active when Raycast is closed. Existing website blocks are preserved.

Unfinished focus rounds cannot be unblocked. Outside focus, unblocking requires a one-minute wait, a short reason, and confirmation. Pomodoro pauses focus time while your Mac is locked or asleep; reopening the timer recovers unfinished progress.

Reopen **Pomodoro** after installation. The posture coach stays off until you enable and calibrate it.

Other apps running as your account can also use the helper to manage website blocks. This is a productivity tool, not tamper-proof access control.
`;

async function openTerminal() {
  await Clipboard.copy(SETUP_COMMAND);
  await open("/System/Applications/Utilities/Terminal.app");
  await showHUD("Setup command copied. Paste it into Terminal.");
}

/**
 * `onCheckAgain` lets the view that showed these instructions reload itself once setup is done;
 * `pushed` instructions also go back to it.
 */
export default function SetupInstructions(props: { onCheckAgain?: () => Promise<boolean>; pushed?: boolean }) {
  const { pop } = useNavigation();
  const [checking, setChecking] = useState(false);

  async function checkAgain() {
    if (checking) return;
    setChecking(true);
    const toast = await showToast({ style: Toast.Style.Animated, title: "Checking setup…" });
    try {
      const done = props.onCheckAgain ? await props.onCheckAgain() : (await verifySetup()).ok;
      toast.style = done ? Toast.Style.Success : Toast.Style.Failure;
      toast.title = done ? "Setup is complete" : "Setup is not complete yet";
      toast.message = done ? undefined : "Run the setup command in Terminal, then check again.";
      if (done && props.pushed) pop();
    } catch (error) {
      toast.style = Toast.Style.Failure;
      toast.title = "Could not check setup";
      toast.message = errorMessage(error);
    } finally {
      setChecking(false);
    }
  }

  return (
    <Detail
      isLoading={checking}
      markdown={markdown}
      actions={
        <ActionPanel>
          <Action title="Copy Command and Open Terminal" icon={Icon.Terminal} onAction={openTerminal} />
          <Action
            title="Check Again"
            icon={Icon.ArrowClockwise}
            shortcut={Keyboard.Shortcut.Common.Refresh}
            onAction={checkAgain}
          />
          <Action.CopyToClipboard
            title="Copy Setup Command"
            content={SETUP_COMMAND}
            shortcut={Keyboard.Shortcut.Common.Copy}
          />
          <Action.Paste title="Paste Setup Command" content={SETUP_COMMAND} />
        </ActionPanel>
      }
    />
  );
}
