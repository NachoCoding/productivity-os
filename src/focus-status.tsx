import { environment, Icon, LaunchType, MenuBarExtra, showHUD, showToast, Toast } from "@raycast/api";
import { amphetamineInstalled } from "./amphetamine";
import { useBlocker } from "./blocker-state";
import { useCachedQuery } from "./cached-query";
import { colorFiltersEnabled, describeColorFilters, toggleColorFilters } from "./color-filters";
import { openCommand, openUnblockReview } from "./launch";
import {
  canStartFocus,
  describeLock,
  describePomodoro,
  errorMessage,
  focusLock,
  formatClock,
  formatRemaining,
  siteUnblockOperations,
} from "./lib";
import { lockAndKeepAwake } from "./lock-keep-awake";
import { describeMenuBarState, menuBarIconsState, toggleMenuBarIcons } from "./menu-bar-icons";
import { describeGuard, resourceGuardStatus } from "./resource-guard-client";

const quiet = () => undefined;

async function report(title: string, action: () => Promise<string | void>) {
  try {
    const text = await action();
    if (text) await showHUD(text);
  } catch (error) {
    await showToast({ style: Toast.Style.Failure, title, message: errorMessage(error) });
  }
}

// Raycast re-runs this command when the menu is opened and on the manifest `interval`, then unloads
// it once nothing is loading, so `isLoading` must cover every read. Each run starts from the values
// cached by any command, so the icon and countdown do not blink while it reloads.
export default function FocusStatus() {
  // The minute-by-minute background runs refresh the countdown and blocks only; the other rows keep
  // their cached values until the menu is opened.
  const background = environment.launchType === LaunchType.Background;
  const blocker = useBlocker();
  const filters = useCachedQuery("color-filters", colorFiltersEnabled, { execute: !background, onError: quiet });
  const menuBar = useCachedQuery("menu-bar-icons", menuBarIconsState, { execute: !background, onError: quiet });
  const guard = useCachedQuery("resource-guard", resourceGuardStatus, { execute: !background, onError: quiet });
  const amphetamine = useCachedQuery("amphetamine-installed", amphetamineInstalled, {
    execute: !background,
    onError: quiet,
  });

  const status = blocker.status;
  const session = status?.session ?? undefined;
  const pomodoro = status?.pomodoro ?? undefined;
  const blocked = status?.entries ?? [];
  const lock = focusLock(status);
  const failed = !!blocker.error;
  const endTime = session ? formatClock(session.endsAt) : "";
  const leftovers = !session && blocked.some((entry) => entry.tag.split(",").includes("focus"));
  // A site and its www twin are one row: unblocking either removes both.
  const sites = [...new Map(blocked.map((entry) => [entry.domain.replace(/^www\./, ""), entry])).keys()].map(
    (domain) => ({
      domain,
      tags: [
        ...new Set(
          blocked
            .filter((entry) => entry.domain.replace(/^www\./, "") === domain)
            .flatMap((entry) => entry.tag.split(",")),
        ),
      ],
    }),
  );

  return (
    <MenuBarExtra
      icon={failed ? Icon.ExclamationMark : session || blocked.length ? Icon.Lock : Icon.LockUnlocked}
      title={session ? formatRemaining(session.endsAt - Date.now()) : undefined}
      isLoading={[blocker, filters, menuBar, guard, amphetamine].some((query) => query.isLoading)}
      tooltip={
        failed
          ? "Could not read focus status"
          : pomodoro
            ? describePomodoro(pomodoro)
            : session
              ? `${session.label} until ${endTime}`
              : "Productivity OS"
      }
    >
      {blocker.setup === false ? (
        <MenuBarExtra.Item title="Set Up Productivity OS…" icon={Icon.Gear} onAction={() => openCommand("run-setup")} />
      ) : blocker.setup === undefined ? null : (
        <>
          <MenuBarExtra.Item
            title={pomodoro ? `Pomodoro: ${describePomodoro(pomodoro)}` : "Start Pomodoro"}
            icon={Icon.Stopwatch}
            onAction={() => openCommand(pomodoro ? "pomodoro" : "start-pomodoro")}
          />
          <MenuBarExtra.Item
            icon={failed ? Icon.ExclamationMark : session ? Icon.Stopwatch : Icon.Circle}
            title={
              failed
                ? "Could not read status — retry"
                : session
                  ? `${session.label} — until ${endTime}`
                  : "No active focus session"
            }
            onAction={() => blocker.revalidate()}
          />
          {/* During focus the helper refuses new sessions and unblocks: say until when instead. */}
          {lock ? (
            <MenuBarExtra.Item title={describeLock(lock)} icon={Icon.Lock} />
          ) : (
            status &&
            canStartFocus(status) && (
              <MenuBarExtra.Item
                title="Start Focus Session…"
                icon={Icon.Play}
                onAction={() => openCommand("start-focus-session")}
              />
            )
          )}
          {pomodoro?.stalled && (
            <MenuBarExtra.Item
              title="End Stalled Round…"
              icon={Icon.Stop}
              onAction={() => openUnblockReview([["end-pomodoro"]])}
            />
          )}
          {!lock && leftovers && (
            <MenuBarExtra.Item
              title="Review Leftover Focus Blocks…"
              icon={Icon.Stop}
              onAction={() => openUnblockReview([["end-focus"]])}
            />
          )}
        </>
      )}
      <MenuBarExtra.Separator />
      <MenuBarExtra.Item
        title={`Resource Guard: ${describeGuard(guard.data)}`}
        icon={Icon.Shield}
        onAction={() => openCommand("resource-guard")}
      />
      {blocker.setup && !lock && blocked.length > 0 && (
        <MenuBarExtra.Submenu title={`Unblock Site (${sites.length})`} icon={Icon.LockUnlocked}>
          {sites.map((site) => (
            <MenuBarExtra.Item
              key={site.domain}
              title={site.domain}
              subtitle={site.tags.join(", ")}
              onAction={() => openUnblockReview(siteUnblockOperations(site.domain, blocked))}
            />
          ))}
          <MenuBarExtra.Separator />
          <MenuBarExtra.Item
            title="Unblock All Sites"
            icon={Icon.LockUnlocked}
            onAction={() => openUnblockReview([["remove-everything"]])}
          />
        </MenuBarExtra.Submenu>
      )}
      <MenuBarExtra.Item title="Blocked Sites…" icon={Icon.List} onAction={() => openCommand("blocked-sites")} />
      <MenuBarExtra.Item title="Block Preset…" icon={Icon.Layers} onAction={() => openCommand("block-preset")} />
      <MenuBarExtra.Submenu title="Tools" icon={Icon.AppWindowGrid2x2}>
        <MenuBarExtra.Item
          title="Screenshot Studio…"
          icon={Icon.Camera}
          onAction={() => openCommand("screenshot-studio")}
        />
        <MenuBarExtra.Item
          title="Clipboard History…"
          icon={Icon.Clipboard}
          onAction={() => openCommand("clipboard-history")}
        />
        <MenuBarExtra.Item title="New Drop Shelf" icon={Icon.Tray} onAction={() => openCommand("drop-shelf")} />
        <MenuBarExtra.Item
          title="Health Break Settings…"
          icon={Icon.Heart}
          onAction={() => openCommand("health-breaks")}
        />
      </MenuBarExtra.Submenu>
      <MenuBarExtra.Section title="Screen">
        <MenuBarExtra.Item
          title={
            filters.error ? "Color Filters: Unavailable" : filters.data ? "Color Filters: On" : "Color Filters: Off"
          }
          icon={filters.data ? Icon.CheckCircle : Icon.Circle}
          onAction={() =>
            report("Could not switch color filters", async () => {
              const enabled = await toggleColorFilters();
              filters.mutate(enabled);
              return describeColorFilters(enabled);
            })
          }
        />
        <MenuBarExtra.Item
          title={
            menuBar.error
              ? "Menu Bar Icons: Unavailable"
              : menuBar.data === "hidden"
                ? "Menu Bar Icons: Hidden"
                : "Menu Bar Icons: Shown"
          }
          icon={menuBar.data === "hidden" ? Icon.EyeDisabled : Icon.Eye}
          onAction={() =>
            report("Could not switch menu bar icons", async () => {
              const state = await toggleMenuBarIcons();
              menuBar.mutate(state);
              return describeMenuBarState(state);
            })
          }
        />
      </MenuBarExtra.Section>
      <MenuBarExtra.Section>
        {amphetamine.data !== false && (
          <MenuBarExtra.Item
            title="Lock Screen and Keep Awake"
            icon={Icon.Lock}
            onAction={() =>
              report("Could not lock and keep awake", async () => {
                if (amphetamine.data === undefined && !(await amphetamineInstalled())) {
                  throw new Error("Amphetamine is not installed");
                }
                // It shows the only HUD.
                await lockAndKeepAwake();
              })
            }
          />
        )}
        <MenuBarExtra.Item
          title="Open Productivity OS…"
          icon={Icon.AppWindowGrid2x2}
          onAction={() => openCommand("dashboard")}
        />
      </MenuBarExtra.Section>
    </MenuBarExtra>
  );
}
