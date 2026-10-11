import {
  Action,
  ActionPanel,
  closeMainWindow,
  Color,
  Icon,
  Keyboard,
  List,
  popToRoot,
  showHUD,
  showToast,
  Toast,
  useNavigation,
} from "@raycast/api";
import { useRef } from "react";
import { LockedAction } from "./blocked-sites";
import { forgetSetup, updateCachedStatus, useBlocker } from "./blocker-state";
import { blockDomains, errorMessage, focusLock, needsSetup, tagUnblockOperations, withBlocks } from "./lib";
import { Preset, presets } from "./presets";
import SetupInstructions from "./show-setup";
import { UnlockForm } from "./unlock-request";

export default function BlockPreset() {
  return <BlockPresetList />;
}

export function BlockPresetList() {
  const { push } = useNavigation();
  const busy = useRef(false);
  const blocker = useBlocker();

  if (blocker.setup === false) return <SetupInstructions onCheckAgain={blocker.recheck} />;
  const status = blocker.status;
  if (!status && !blocker.error) return <List isLoading />;

  if (blocker.error || !status) {
    return (
      <List isLoading={blocker.isLoading}>
        <List.EmptyView
          icon={Icon.ExclamationMark}
          title="Could not read blocked sites"
          description={errorMessage(blocker.error)}
          actions={
            <ActionPanel>
              <Action title="Retry" icon={Icon.ArrowClockwise} onAction={() => blocker.revalidate()} />
            </ActionPanel>
          }
        />
      </List>
    );
  }

  const lock = focusLock(status);
  const owns = (domain: string, tag: string) =>
    status.entries.some((entry) => entry.domain === domain && entry.tag.split(",").includes(tag));

  // Adding blocks is allowed even during focus; only removals wait for the review.
  const block = async (preset: Preset) => {
    if (busy.current) return;
    busy.current = true;
    try {
      await blockDomains(preset.domains, preset.name);
      updateCachedStatus((current) => withBlocks(current, preset.domains, preset.name));
      await closeMainWindow();
      await showHUD(`🔒 Blocked ${preset.title} (${preset.domains.length} sites)`);
      await popToRoot();
    } catch (error) {
      if (needsSetup(error)) {
        forgetSetup();
        void blocker.recheck();
      }
      await showToast({ style: Toast.Style.Failure, title: "Could not update preset", message: errorMessage(error) });
    } finally {
      busy.current = false;
    }
  };

  return (
    <List isLoading={blocker.isLoading} searchBarPlaceholder="Search presets…">
      {presets.map((preset) => {
        const blockedCount = preset.domains.filter((d) => owns(d, preset.name)).length;
        const total = preset.domains.length;
        const partial = blockedCount > 0 && blockedCount < total;
        const isBlocked = blockedCount > 0;
        const unblock = lock ? (
          <LockedAction lock={lock} />
        ) : (
          <Action
            title={`Unblock ${preset.title}`}
            icon={Icon.LockUnlocked}
            onAction={() =>
              push(<UnlockForm operations={tagUnblockOperations(preset.name, status?.entries ?? [])} pushed />)
            }
          />
        );
        return (
          <List.Item
            key={preset.name}
            icon={preset.icon}
            title={preset.title}
            subtitle={preset.domains.filter((d) => !d.startsWith("www.")).join(", ")}
            keywords={preset.domains}
            accessories={[
              {
                tag: isBlocked
                  ? {
                      value: partial ? `${blockedCount}/${total} blocked` : "blocked",
                      color: partial ? Color.Orange : Color.Green,
                    }
                  : { value: `${total} sites` },
              },
            ]}
            actions={
              <ActionPanel>
                {isBlocked ? (
                  unblock
                ) : (
                  <Action title={`Block ${preset.title}`} icon={Icon.Lock} onAction={() => block(preset)} />
                )}
                {partial && (
                  <Action
                    title={`Block Remaining ${total - blockedCount}`}
                    icon={Icon.Lock}
                    onAction={() => block(preset)}
                  />
                )}
                <Action
                  title="Refresh"
                  icon={Icon.ArrowClockwise}
                  onAction={() => blocker.revalidate()}
                  shortcut={Keyboard.Shortcut.Common.Refresh}
                />
              </ActionPanel>
            }
          />
        );
      })}
    </List>
  );
}
