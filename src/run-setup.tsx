import { Action, ActionPanel, Color, Icon, Keyboard, List, showToast, Toast } from "@raycast/api";
import { useRef } from "react";
import { useBlocker } from "./blocker-state";
import { useCachedQuery } from "./cached-query";
import { errorMessage, repairState } from "./lib";
import SetupInstructions, { helperNeedsUpdate, SETUP_COMMAND } from "./show-setup";

export default function RunSetup() {
  // This command exists to verify the installation, so it always checks setup again.
  const blocker = useBlocker({ recheckSetup: true });
  const update = useCachedQuery("helper-update", helperNeedsUpdate, { execute: blocker.setup === true });
  const repairing = useRef(false);

  if (blocker.setup === false) return <SetupInstructions onCheckAgain={blocker.recheck} />;
  if (blocker.setup === undefined) return <List isLoading />;

  const status = blocker.status;
  const blocked = status?.entries ?? [];
  const tagsOf = (tag: string) => tag.split(",").filter(Boolean);
  const manual = blocked.filter((entry) => tagsOf(entry.tag).includes("manual")).length;
  const focus = blocked.filter((entry) => tagsOf(entry.tag).includes("focus")).length;
  const preset = blocked.filter((entry) => tagsOf(entry.tag).some((tag) => tag !== "manual" && tag !== "focus")).length;
  const summary = blocker.error
    ? `Helper installed, but its status could not be read: ${errorMessage(blocker.error)}`
    : `${blocked.length} site${blocked.length === 1 ? "" : "s"} blocked: ${manual} manual, ${preset} preset, ${focus} focus.`;

  async function repair() {
    if (repairing.current) return;
    repairing.current = true;
    const toast = await showToast({ style: Toast.Style.Animated, title: "Repairing Pomodoro state…" });
    try {
      const repaired = await repairState();
      toast.style = Toast.Style.Success;
      toast.title = repaired ? "Pomodoro state repaired" : "Pomodoro state was already healthy";
      toast.message = repaired ? "Any unfinished round was kept as a paused recovery round." : undefined;
    } catch (error) {
      toast.style = Toast.Style.Failure;
      toast.title = "Could not repair the Pomodoro state";
      toast.message = errorMessage(error);
    } finally {
      repairing.current = false;
    }
    await blocker.revalidate();
  }

  const copy = <Action.CopyToClipboard title="Copy Setup Command" content={SETUP_COMMAND} />;
  const refresh = (
    <Action
      title="Refresh"
      icon={Icon.ArrowClockwise}
      onAction={() => {
        void blocker.recheck();
        void update.revalidate();
      }}
      shortcut={Keyboard.Shortcut.Common.Refresh}
    />
  );
  const actions = (
    <ActionPanel>
      {copy}
      {refresh}
    </ActionPanel>
  );

  return (
    <List isLoading={blocker.isLoading || update.isLoading} searchBarPlaceholder="Search blocked sites…">
      <List.Section title="Status">
        <List.Item
          icon={{ source: Icon.CheckCircle, tintColor: Color.Green }}
          title="Setup complete"
          subtitle={summary}
          accessories={[
            {
              text: status ? `helper v${status.version}` : "helper",
              tooltip: "Root-owned helper and expiry daemon are installed",
            },
          ]}
          actions={actions}
        />
        {status?.stateDamaged && (
          <List.Item
            icon={{ source: Icon.Warning, tintColor: Color.Orange }}
            title="Pomodoro state needs repair"
            subtitle="Its saved state is damaged; website blocks still work and were preserved."
            actions={
              <ActionPanel>
                <Action title="Repair Pomodoro State" icon={Icon.Hammer} onAction={repair} />
                {copy}
                {refresh}
              </ActionPanel>
            }
          />
        )}
        {update.data && (
          <List.Item
            icon={{ source: Icon.ArrowClockwise, tintColor: Color.Orange }}
            title="Helper update available"
            subtitle="The bundled helper or focus probe differs from the installed copy. Rerun the setup command."
            actions={actions}
          />
        )}
      </List.Section>
      <List.Section title="Blocked sites" subtitle={String(blocked.length)}>
        {blocked.map((entry) => (
          <List.Item
            key={entry.domain}
            icon={Icon.Lock}
            title={entry.domain}
            accessories={tagsOf(entry.tag).map((tag) => ({ tag }))}
            actions={actions}
          />
        ))}
      </List.Section>
    </List>
  );
}
