import { Action, ActionPanel, Color, Icon, Keyboard, List, showToast, Toast, useNavigation } from "@raycast/api";
import { useRef } from "react";
import {
  AMPHETAMINE_URL,
  AwakeStatus,
  awakeStatus,
  describeKeepAwake,
  endAwakeSession,
  startKeepAwake,
} from "./amphetamine";
import ConfigureNewSession from "./amphetamine-configure";
import { formatRemainingSeconds, formatShortDuration } from "./amphetamine-time";
import { BlockedSitesList, LockedAction } from "./blocked-sites";
import { useBlocker } from "./blocker-state";
import { useCachedQuery } from "./cached-query";
import { clipboardAction } from "./clipboard-history-client";
import { colorFiltersEnabled, describeColorFilters, toggleColorFilters } from "./color-filters";
import { shelfAction } from "./drop-shelf-client";
import { healthAction } from "./health-breaks-client";
import {
  blockDomains,
  canStartFocus,
  describeLock,
  describePomodoro,
  errorMessage,
  focusLock,
  formatClock,
  formatRemaining,
  tagUnblockOperations,
  UnblockOperation,
} from "./lib";
import { lockAndKeepAwake } from "./lock-keep-awake";
import { describeMenuBarState, menuBarIconsState, toggleMenuBarIcons } from "./menu-bar-icons";
import { presets } from "./presets";
import ResourceGuard from "./resource-guard";
import RunSetup from "./run-setup";
import { describeGuard, resourceGuardStatus } from "./resource-guard-client";
import ScreenshotStudio from "./screenshot-studio";
import SetupInstructions from "./show-setup";
import { StartFocusSessionForm } from "./start-focus-session";
import { UnlockForm } from "./unlock-request";

const AWAKE_MINUTES = [30, 60, 120, 240];

const on = (label = "On") => ({ tag: { value: label, color: Color.Green } });
const off = (label = "Off") => ({ tag: { value: label, color: Color.SecondaryText } });
const unknown = () => ({ tag: { value: "Unavailable", color: Color.Orange } });

function awakeAccessory(status: AwakeStatus) {
  if (status.state !== "active") return off();
  if (status.remaining > 0) return on(`${formatRemainingSeconds(status.remaining)} left`);
  return on(status.remaining === 0 ? "No time limit" : "On");
}

/**
 * Every Productivity OS switch on one screen: press ↵ on a row to flip it. Rows open with the values
 * any command last read (shared cache) and refresh in place; an action reloads only what it changed.
 */
export default function Dashboard() {
  const { push } = useNavigation();
  const blocker = useBlocker();
  // A row that cannot be read says so itself; none of these raise failure toasts.
  const filters = useCachedQuery("color-filters", colorFiltersEnabled);
  const menuBar = useCachedQuery("menu-bar-icons", menuBarIconsState);
  const awake = useCachedQuery("keep-awake", awakeStatus);
  const guard = useCachedQuery("resource-guard", resourceGuardStatus);
  const busy = useRef(false);

  const refresh = () => {
    for (const query of [blocker, filters, menuBar, awake, guard]) void query.revalidate();
  };

  /**
   * Runs one switch at a time (a second ↵ while one runs is ignored) and reports it in a toast;
   * an action that shows its own HUD returns nothing. `reload` refreshes only the affected row.
   */
  const act = async (working: string, action: () => Promise<string | void>, reload?: () => unknown) => {
    if (busy.current) return;
    busy.current = true;
    try {
      const toast = await showToast({ style: Toast.Style.Animated, title: working });
      try {
        const title = await action();
        if (title) {
          toast.style = Toast.Style.Success;
          toast.title = title;
        } else {
          await toast.hide();
        }
      } catch (error) {
        toast.style = Toast.Style.Failure;
        toast.title = "That did not work";
        toast.message = errorMessage(error);
      }
    } finally {
      busy.current = false;
    }
    await reload?.();
  };

  // Toggles report the state they produced, so the row flips at once and is not read again.
  const flipFilters = () =>
    act("Switching color filters…", async () => {
      if (filters.data !== undefined) filters.mutate(!filters.data);
      try {
        const enabled = await toggleColorFilters();
        filters.mutate(enabled);
        return describeColorFilters(enabled);
      } catch (error) {
        void filters.revalidate();
        throw error;
      }
    });
  const flipMenuBar = () =>
    act("Switching menu bar icons…", async () => {
      if (menuBar.data !== undefined) menuBar.mutate(menuBar.data === "hidden" ? "visible" : "hidden");
      try {
        const state = await toggleMenuBarIcons();
        menuBar.mutate(state);
        return describeMenuBarState(state);
      } catch (error) {
        void menuBar.revalidate();
        throw error;
      }
    });
  const keepAwakeFor = (minutes: number) =>
    act(
      "Starting session…",
      async () => describeKeepAwake(minutes, await startKeepAwake(minutes)),
      () => awake.revalidate(),
    );
  const lock = (minutes: number) =>
    act(
      "Locking…",
      async () => {
        await lockAndKeepAwake(minutes);
      },
      () => awake.revalidate(),
    );
  const review = (operations: UnblockOperation[]) => push(<UnlockForm operations={operations} pushed />);
  const setupInstructions = () => push(<SetupInstructions onCheckAgain={blocker.recheck} pushed />);

  const refreshAction = (
    <Action title="Refresh" icon={Icon.ArrowClockwise} shortcut={Keyboard.Shortcut.Common.Refresh} onAction={refresh} />
  );

  const status = blocker.status;
  const readFailed = !!blocker.error;
  const session = status?.session ?? undefined;
  const pomodoro = status?.pomodoro ?? undefined;
  const focusLocked = focusLock(status);
  const entries = status?.entries ?? [];
  const owns = (domain: string, tag: string) =>
    entries.some((entry) => entry.domain === domain && entry.tag.split(",").includes(tag));
  const lockedAction = focusLocked && <LockedAction lock={focusLocked} />;
  const endStalled = pomodoro?.stalled && (
    <Action title="End Stalled Round…" icon={Icon.Stop} onAction={() => review([["end-pomodoro"]])} />
  );
  const openPomodoro = (
    <Action
      title={pomodoro ? "Open Pomodoro" : "Start Pomodoro"}
      icon={Icon.Stopwatch}
      onAction={() =>
        blocker.setup === false ? setupInstructions() : healthAction(pomodoro ? "pomodoro" : "pomodoro-start")
      }
    />
  );

  return (
    <List
      isLoading={[blocker, filters, menuBar, awake, guard].some((query) => query.isLoading)}
      searchBarPlaceholder="Search tools, settings, and actions…"
    >
      <List.EmptyView
        title="No matching tools"
        description="Try screenshot, clipboard, shelf, health, RAM, or focus."
      />
      <List.Section title="Computer Resources">
        <List.Item
          id="resource-guard"
          title="Resource Guard"
          subtitle={describeGuard(guard.data)}
          icon={Icon.Shield}
          keywords={["ram", "memory", "cpu", "warp", "codex", "claude"]}
          actions={
            <ActionPanel>
              <Action title="Open Resource Guard" icon={Icon.Shield} onAction={() => push(<ResourceGuard />)} />
              {refreshAction}
            </ActionPanel>
          }
        />
      </List.Section>
      <List.Section title="Focus">
        <List.Item
          id="pomodoro"
          title="Pomodoro"
          icon={Icon.Stopwatch}
          subtitle={
            readFailed
              ? "Could not read Pomodoro"
              : status?.stateDamaged
                ? "Its saved state is damaged · repair it in Run Setup"
                : describePomodoro(pomodoro)
          }
          keywords={["timer", "focus", "break", "25", "5"]}
          accessories={
            status?.stateDamaged
              ? [{ tag: { value: "Needs Repair", color: Color.Orange } }]
              : !pomodoro
                ? []
                : pomodoro.stalled
                  ? [{ tag: { value: "Stalled", color: Color.Orange } }]
                  : pomodoro.paused
                    ? [on(pomodoro.phase === "focus" ? "Paused · sites locked" : "Paused")]
                    : [on(`Round ${pomodoro.completedRounds + 1}`)]
          }
          actions={
            <ActionPanel>
              {status?.stateDamaged && (
                <Action title="Repair in Run Setup" icon={Icon.Hammer} onAction={() => push(<RunSetup />)} />
              )}
              {openPomodoro}
              {endStalled}
              <Action title="Pomodoro Settings" icon={Icon.Gear} onAction={() => healthAction("pomodoro-settings")} />
              {refreshAction}
            </ActionPanel>
          }
        />
      </List.Section>
      <List.Section title="Health">
        <List.Item
          title="Health Breaks"
          subtitle="Eye, stretch, and water reminders · optional posture coaching"
          icon={Icon.Heart}
          keywords={["health", "eyes", "stretch", "water", "reminders", "posture", "camera"]}
          actions={
            <ActionPanel>
              <Action title="Health Break Settings" onAction={() => healthAction("settings")} />
              <Action title="Posture Coach" onAction={() => healthAction("posture")} />
              <Action title="Take a Break Now" onAction={() => healthAction("break")} />
              <Action title="Preview Reminder" onAction={() => healthAction("preview")} />
            </ActionPanel>
          }
        />
      </List.Section>
      <List.Section title="Files">
        <List.Item
          title="Drop Shelf"
          subtitle="Collect and drag files between apps · ⌥⇧Space"
          icon={Icon.Tray}
          keywords={["dropover", "shelf", "drag", "drop"]}
          actions={
            <ActionPanel>
              <Action title="New Shelf" onAction={() => shelfAction("new")} />
              <Action title="Add Clipboard to Shelf" onAction={() => shelfAction("clipboard")} />
              <Action title="Drop Shelf Settings" onAction={() => shelfAction("settings")} />
            </ActionPanel>
          }
        />
      </List.Section>
      <List.Section title="Clipboard">
        <List.Item
          title="Clipboard History"
          keywords={["copy", "paste", "history", "flycut", "text"]}
          subtitle="Search copied text and code · ⌘⇧V"
          icon={Icon.Clipboard}
          actions={
            <ActionPanel>
              <Action title="Open Clipboard History" onAction={() => clipboardAction("history")} />
              <Action title="Clipboard History Settings" onAction={() => clipboardAction("settings")} />
            </ActionPanel>
          }
        />
      </List.Section>
      <List.Section title="Screen">
        <List.Item
          title="Screenshot Studio"
          subtitle="Capture, annotate, scroll, and record · ⌘⇧2"
          keywords={["screenshot", "capture", "ocr", "record", "scroll", "shottr"]}
          icon={Icon.Camera}
          actions={
            <ActionPanel>
              <Action title="Open Screenshot Studio" onAction={() => push(<ScreenshotStudio />)} />
            </ActionPanel>
          }
        />
        <List.Item
          id="color-filters"
          icon={{ source: Icon.CircleProgress50, tintColor: filters.data ? Color.PrimaryText : Color.SecondaryText }}
          title="Color Filters"
          subtitle={filters.error ? "Could not read the setting" : "Grayscale or your chosen filter"}
          keywords={["grayscale", "greyscale", "display", "accessibility"]}
          accessories={filters.error ? [unknown()] : filters.data === undefined ? [] : [filters.data ? on() : off()]}
          actions={
            <ActionPanel>
              <Action
                title={
                  filters.data === undefined
                    ? "Toggle Color Filters"
                    : filters.data
                      ? "Turn off Color Filters"
                      : "Turn on Color Filters"
                }
                icon={Icon.CircleProgress50}
                onAction={flipFilters}
              />
              {refreshAction}
            </ActionPanel>
          }
        />
        <List.Item
          id="menu-bar-icons"
          icon={{
            source: menuBar.data === "hidden" ? Icon.EyeDisabled : Icon.Eye,
            tintColor: menuBar.data === "hidden" ? Color.PrimaryText : Color.SecondaryText,
          }}
          title="Menu Bar Icons"
          subtitle={
            menuBar.error
              ? "Could not read menu bar visibility"
              : menuBar.data === "stopped"
                ? "Hide the icons left of the ‹ divider"
                : "Hold ⌘ and drag icons across ‹"
          }
          keywords={["hide", "show", "status", "tray", "divider"]}
          accessories={
            menuBar.error
              ? [unknown()]
              : menuBar.data === undefined
                ? []
                : [menuBar.data === "hidden" ? on("Hidden") : off("Shown")]
          }
          actions={
            <ActionPanel>
              <Action
                title={menuBar.data === "hidden" ? "Show Menu Bar Icons" : "Hide Menu Bar Icons"}
                icon={menuBar.data === "hidden" ? Icon.Eye : Icon.EyeDisabled}
                onAction={flipMenuBar}
              />
              {refreshAction}
            </ActionPanel>
          }
        />
        {awake.data?.state !== "missing" && (
          <List.Item
            id="lock"
            icon={{ source: Icon.Lock, tintColor: Color.SecondaryText }}
            title="Lock Screen and Keep Awake"
            subtitle="Step away while agents and downloads keep running"
            keywords={["lock", "away", "afk"]}
            actions={
              <ActionPanel>
                <Action title="Lock Now" icon={Icon.Lock} onAction={() => lock(0)} />
                <ActionPanel.Section title="Lock and Stay Awake For">
                  {AWAKE_MINUTES.map((minutes) => (
                    <Action
                      key={minutes}
                      title={formatShortDuration(minutes)}
                      icon={Icon.Clock}
                      onAction={() => lock(minutes)}
                    />
                  ))}
                </ActionPanel.Section>
                {refreshAction}
              </ActionPanel>
            }
          />
        )}
      </List.Section>

      <List.Section title="Keep Awake">
        {awake.data?.state === "missing" ? (
          <List.Item
            id="keep-awake"
            icon={{ source: Icon.Download, tintColor: Color.Orange }}
            title="Install Amphetamine"
            subtitle="Free app that keeps your Mac awake"
            actions={
              <ActionPanel>
                <Action.OpenInBrowser title="Open in App Store" url={AMPHETAMINE_URL} />
                {refreshAction}
              </ActionPanel>
            }
          />
        ) : (
          <List.Item
            id="keep-awake"
            icon={{
              source: awake.data?.state === "active" ? Icon.MugSteam : Icon.Mug,
              tintColor: awake.data?.state === "active" ? Color.Orange : Color.SecondaryText,
            }}
            title="Keep Awake"
            subtitle={
              awake.error ? "Could not reach Amphetamine" : "Stop the Mac from sleeping · replaces a running session"
            }
            keywords={["amphetamine", "sleep", "caffeine", "awake"]}
            accessories={awake.error ? [unknown()] : awake.data ? [awakeAccessory(awake.data)] : []}
            actions={
              <ActionPanel>
                {awake.data?.state === "active" && (
                  <Action
                    title="End Session"
                    icon={Icon.Stop}
                    onAction={() =>
                      act(
                        "Ending session…",
                        async () => {
                          await endAwakeSession();
                          return "😴 Keep awake ended";
                        },
                        () => awake.revalidate(),
                      )
                    }
                  />
                )}
                <ActionPanel.Section title="Keep Awake For">
                  {AWAKE_MINUTES.map((minutes) => (
                    <Action
                      key={minutes}
                      title={formatShortDuration(minutes)}
                      icon={Icon.Clock}
                      onAction={() => keepAwakeFor(minutes)}
                    />
                  ))}
                  <Action title="No Time Limit" icon={Icon.Bolt} onAction={() => keepAwakeFor(0)} />
                  <Action
                    title="Custom Duration or End Time…"
                    icon={Icon.Pencil}
                    onAction={() => push(<ConfigureNewSession />)}
                  />
                </ActionPanel.Section>
                {refreshAction}
              </ActionPanel>
            }
          />
        )}
      </List.Section>

      <List.Section title="Websites">
        {blocker.setup === false ? (
          <List.Item
            id="setup"
            icon={{ source: Icon.Gear, tintColor: Color.Orange }}
            title="Set Up Website Blocking"
            subtitle="One Terminal command, needed once"
            actions={
              <ActionPanel>
                <Action title="Show Setup Command" icon={Icon.Gear} onAction={setupInstructions} />
                {refreshAction}
              </ActionPanel>
            }
          />
        ) : (
          <>
            <List.Item
              id="focus-session"
              icon={{ source: Icon.Stopwatch, tintColor: session ? Color.Blue : Color.SecondaryText }}
              title="Focus Session"
              subtitle={
                readFailed
                  ? "Could not read the session"
                  : session
                    ? `${session.label} until ${formatClock(session.endsAt)}`
                    : pomodoro && !focusLocked
                      ? "Stop the Pomodoro to start a different timer"
                      : "Block distractions for a set time"
              }
              keywords={["timer", "pomodoro", "block"]}
              accessories={
                readFailed
                  ? [unknown()]
                  : !status
                    ? []
                    : session
                      ? [on(`${formatRemaining(session.endsAt - Date.now())} left`)]
                      : focusLocked
                        ? [{ tag: { value: describeLock(focusLocked), color: Color.Blue } }]
                        : [off()]
              }
              actions={
                <ActionPanel>
                  {lockedAction}
                  {endStalled}
                  {status && canStartFocus(status) && (
                    <Action
                      title="Start Focus Session…"
                      icon={Icon.Play}
                      onAction={() => push(<StartFocusSessionForm preloaded />)}
                    />
                  )}
                  {status && !focusLocked && pomodoro && openPomodoro}
                  {refreshAction}
                </ActionPanel>
              }
            />
            {presets.map((preset) => {
              const count = preset.domains.filter((domain) => owns(domain, preset.name)).length;
              const total = preset.domains.length;
              return (
                <List.Item
                  key={preset.name}
                  id={`preset-${preset.name}`}
                  icon={preset.icon}
                  title={`Block ${preset.title}`}
                  subtitle={preset.domains.filter((domain) => !domain.startsWith("www.")).join(", ")}
                  keywords={preset.domains}
                  accessories={
                    readFailed
                      ? [unknown()]
                      : !status
                        ? []
                        : count === 0
                          ? [off()]
                          : count < total
                            ? [{ tag: { value: `${count}/${total} blocked`, color: Color.Orange } }]
                            : [on("Blocked")]
                  }
                  actions={
                    <ActionPanel>
                      {count < total && (
                        <Action
                          title={count ? `Block Remaining ${total - count}` : `Block ${preset.title}`}
                          icon={Icon.Lock}
                          onAction={() =>
                            act(
                              `Blocking ${preset.title}…`,
                              async () => {
                                await blockDomains(preset.domains, preset.name);
                                return `🔒 Blocked ${preset.title}`;
                              },
                              () => blocker.revalidate(),
                            )
                          }
                        />
                      )}
                      {count > 0 &&
                        (lockedAction || (
                          <Action
                            title={`Unblock ${preset.title}`}
                            icon={Icon.LockUnlocked}
                            onAction={() => review(tagUnblockOperations(preset.name, entries))}
                          />
                        ))}
                      {refreshAction}
                    </ActionPanel>
                  }
                />
              );
            })}
            <List.Item
              id="blocked-sites"
              icon={{ source: Icon.List, tintColor: entries.length ? Color.Orange : Color.SecondaryText }}
              title="Blocked Sites"
              subtitle={readFailed ? "Could not read blocked sites" : "See, check and unblock single sites"}
              accessories={readFailed ? [unknown()] : status ? [{ text: `${entries.length} blocked` }] : []}
              actions={
                <ActionPanel>
                  <Action
                    title="Open Blocked Sites"
                    icon={Icon.List}
                    onAction={() => push(<BlockedSitesList preloaded />)}
                  />
                  {refreshAction}
                </ActionPanel>
              }
            />
          </>
        )}
      </List.Section>
    </List>
  );
}
