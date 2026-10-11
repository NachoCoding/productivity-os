import { Action, ActionPanel, Color, Icon, Keyboard, List, showToast, Toast, useNavigation } from "@raycast/api";
import { useState } from "react";
import BlockDiagnostics from "./block-diagnostics";
import { PRELOADED_MS, useBlocker } from "./blocker-state";
import {
  canStartFocus,
  describeLock,
  errorMessage,
  FocusLock,
  focusLock,
  siteUnblockOperations,
  tagUnblockOperations,
  UnblockOperation,
} from "./lib";
import { getPreset } from "./presets";
import SetupInstructions from "./show-setup";
import { StartFocusSessionForm } from "./start-focus-session";
import { UnlockForm } from "./unlock-request";

export default function BlockedSites() {
  return <BlockedSitesList />;
}

const tagTitle = (tag: string) => {
  if (tag === "focus") return "Focus Session";
  if (tag === "pomodoro") return "Pomodoro Sites";
  if (tag === "manual") return "Manual Blocks";
  return `${getPreset(tag)?.title ?? tag} Preset`;
};

/** Stands in for the actions the helper refuses during focus; pressing it explains why. */
export function LockedAction(props: { lock: FocusLock }) {
  const title = describeLock(props.lock);
  return (
    <Action
      title={title}
      icon={Icon.Lock}
      onAction={() =>
        showToast({
          style: Toast.Style.Failure,
          title,
          message: "Blocks can't be removed, and no new focus session can start, until the current focus ends.",
        })
      }
    />
  );
}

/**
 * Shared by the Blocked Sites, Unblock Site and Review Unblock commands. `preloaded` means the opener
 * (the dashboard) has just read the status, so it is not read again on open.
 */
export function BlockedSitesList(props: { initialSearch?: string; preloaded?: boolean }) {
  const blocker = useBlocker({ freshFor: props.preloaded ? PRELOADED_MS : undefined });
  const { push } = useNavigation();
  const [searchText, setSearchText] = useState(props.initialSearch ?? "");

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

  const blocked = status.entries;
  const lock = focusLock(status);
  const startable = canStartFocus(status);
  const review = (operations: UnblockOperation[]) => push(<UnlockForm operations={operations} pushed />);
  const unblockByTag = (tag: string) => review(tagUnblockOperations(tag, blocked));
  const endStalled = status.pomodoro?.stalled && (
    <Action title="End Stalled Round…" icon={Icon.Stop} onAction={() => review([["end-pomodoro"]])} />
  );
  const refresh = (
    <Action
      title="Refresh"
      icon={Icon.ArrowClockwise}
      onAction={() => blocker.revalidate()}
      shortcut={Keyboard.Shortcut.Common.Refresh}
    />
  );

  return (
    <List
      isLoading={blocker.isLoading}
      searchBarPlaceholder="Search blocked sites…"
      filtering
      searchText={searchText}
      onSearchTextChange={setSearchText}
    >
      <List.EmptyView
        icon={Icon.LockUnlocked}
        title={blocked.length ? "No match" : "Nothing blocked"}
        actions={
          <ActionPanel>
            {startable && (
              <Action
                title="Start Focus Session…"
                icon={Icon.Stopwatch}
                onAction={() => push(<StartFocusSessionForm preloaded />)}
              />
            )}
            {refresh}
          </ActionPanel>
        }
        description={
          blocked.length ? "No blocked site matches this search." : "Block a site with the Block Site command."
        }
      />
      {blocked.map((entry) => {
        const tags = entry.tag ? entry.tag.split(",") : [];
        return (
          <List.Item
            key={entry.domain}
            icon={Icon.Lock}
            title={entry.domain}
            keywords={tags}
            accessories={
              tags.length
                ? tags.map((tag) => ({ tag: { value: tag, color: tagColor(tag) } }))
                : [{ tag: { value: "untagged", color: Color.SecondaryText } }]
            }
            actions={
              <ActionPanel>
                <ActionPanel.Section>
                  {lock ? (
                    <>
                      <LockedAction lock={lock} />
                      {endStalled}
                    </>
                  ) : (
                    <>
                      <Action
                        title="Review Unblock…"
                        icon={Icon.LockUnlocked}
                        onAction={() => review(siteUnblockOperations(entry.domain, blocked))}
                      />
                      {tags.map((tag) => (
                        <Action
                          key={tag}
                          title={tag === "focus" ? "End Focus Session" : `Unblock All ${tagTitle(tag)}`}
                          icon={Icon.LockUnlocked}
                          onAction={() => unblockByTag(tag)}
                        />
                      ))}
                    </>
                  )}
                </ActionPanel.Section>
                <ActionPanel.Section>
                  <Action
                    title="Check Block"
                    icon={Icon.CheckCircle}
                    onAction={() => push(<BlockDiagnostics domains={[entry.domain]} />)}
                  />
                  <Action.CopyToClipboard
                    title="Copy Domain"
                    content={entry.domain}
                    shortcut={Keyboard.Shortcut.Common.Copy}
                  />
                  <Action.OpenInBrowser
                    title="Open in Browser (Test Block)"
                    url={`https://${entry.domain}`}
                    shortcut={Keyboard.Shortcut.Common.Open}
                  />
                  {startable && (
                    <Action
                      title="Start Focus Session…"
                      icon={Icon.Stopwatch}
                      shortcut={{ modifiers: ["cmd"], key: "f" }}
                      onAction={() => push(<StartFocusSessionForm preselectedDomains={[entry.domain]} preloaded />)}
                    />
                  )}
                </ActionPanel.Section>
                <ActionPanel.Section title="Bulk">
                  {!lock && (
                    <Action
                      title="Unblock All Sites…"
                      icon={Icon.LockUnlocked}
                      style={Action.Style.Destructive}
                      shortcut={Keyboard.Shortcut.Common.RemoveAll}
                      onAction={() => review([["remove-everything"]])}
                    />
                  )}
                  {refresh}
                </ActionPanel.Section>
              </ActionPanel>
            }
          />
        );
      })}
    </List>
  );
}

function tagColor(tag: string) {
  switch (tag) {
    case "pomodoro":
    case "focus":
      return Color.Blue;
    case "manual":
      return Color.Orange;
    default:
      return Color.Green;
  }
}
