import {
  Action,
  ActionPanel,
  Alert,
  Color,
  Icon,
  Keyboard,
  List,
  confirmAlert,
  open,
  showToast,
  Toast,
} from "@raycast/api";
import { useEffect, useRef } from "react";
import { useCachedQuery } from "./cached-query";
import { errorMessage } from "./lib";
import {
  cancelGuardJob,
  describeGuard,
  formatBytes,
  GuardJob,
  MemoryApp,
  installResourceGuard,
  resourceGuardStatus,
  resourceMemory,
  quitMemoryApp,
  resourcePriority,
  describePriority,
  toggleResourcePriority,
  prioritySetupCommand,
  setGuardLimit,
} from "./resource-guard-client";

const POLL_MS = 5000;

export default function ResourceGuard() {
  // Cached, so the view (and the dashboard and menu bar rows) open with the last reading.
  const query = useCachedQuery("resource-guard", resourceGuardStatus);
  const memory = useCachedQuery("guard-memory", resourceMemory);
  const priority = useCachedQuery("guard-priority", resourcePriority);
  const acting = useRef(false);
  const queries = useRef([query, memory, priority]);
  queries.current = [query, memory, priority];
  // Polls never show the loading bar; only the first load, Refresh and actions do.
  const reload = (silent = false) => Promise.all(queries.current.map((each) => each.revalidate({ silent })));
  useEffect(() => {
    const timer = setInterval(() => {
      // An action reloads everything when it finishes; a poll in between would race it.
      if (!acting.current) void reload(true);
    }, POLL_MS);
    return () => clearInterval(timer);
  }, []);

  const act = async (title: string, action: () => Promise<string>) => {
    if (acting.current) return;
    acting.current = true;
    try {
      const toast = await showToast({ style: Toast.Style.Animated, title });
      try {
        const message = await action();
        toast.style = Toast.Style.Success;
        toast.title = "Resource Guard updated";
        toast.message = message || undefined;
      } catch (error) {
        toast.style = Toast.Style.Failure;
        toast.title = "Resource Guard could not complete the action";
        toast.message = errorMessage(error);
      } finally {
        await reload();
      }
    } finally {
      acting.current = false;
    }
  };
  const quit = async (app: MemoryApp) => {
    if (
      await confirmAlert({
        title: `Quit ${app.name} to make RAM available?`,
        message: `${formatBytes(app.bytes)} estimated app memory across ${app.processCount} processes. The app may ask you to save work. Actual RAM released can differ. Warp and agents stay running.`,
        primaryAction: { title: `Quit ${app.name}`, style: Alert.ActionStyle.Destructive },
      })
    )
      await act(`Asking ${app.name} to quit…`, () => quitMemoryApp(app));
  };
  const cancel = async (job: GuardJob, force: boolean) => {
    if (
      await confirmAlert({
        title: `${force ? "Force stop" : job.state === "queued" ? "Remove queued" : "Cancel"} ${job.name}?`,
        message: `${job.directory}\nThis affects only this guarded job. Unsaved job output may be lost.`,
        primaryAction: { title: force ? "Force Stop" : "Cancel Job", style: Alert.ActionStyle.Destructive },
      })
    ) {
      await act("Cancelling job…", () => cancelGuardJob(job.id, force));
    }
  };
  const status = query.data;
  const snapshot = status?.state === "ready" ? status.snapshot : undefined;
  const sample = snapshot?.sample;
  const stale = !sample || snapshot?.sampleAge === null || (snapshot?.sampleAge ?? 11) > 10;
  const freshMemory =
    !memory.error && memory.data && Date.now() / 1000 - memory.data.measuredAt <= 15 ? memory.data : undefined;
  const commonActions = (
    <>
      <Action
        title="Refresh"
        shortcut={Keyboard.Shortcut.Common.Refresh}
        icon={Icon.ArrowClockwise}
        onAction={() => void reload()}
      />
      <Action
        title="Open Activity Monitor"
        icon={Icon.AppWindow}
        onAction={() => open("/System/Applications/Utilities/Activity Monitor.app")}
      />
      {snapshot && (
        <ActionPanel.Submenu title="Heavy Job Limit" icon={Icon.Gear}>
          {[1, 2].map((limit) => (
            <Action
              key={limit}
              title={`${limit} ${limit === 1 ? "Job" : "Jobs"}`}
              onAction={() => act("Updating limit…", () => setGuardLimit(limit))}
            />
          ))}
        </ActionPanel.Submenu>
      )}
      <Action
        title={status?.state === "missing" ? "Install Resource Guard" : "Repair or Update Resource Guard"}
        icon={Icon.Download}
        onAction={() => act("Installing Resource Guard…", installResourceGuard)}
      />
    </>
  );

  return (
    <List
      isLoading={query.isLoading || memory.isLoading || priority.isLoading}
      searchBarPlaceholder="Search apps, jobs, RAM, or CPU priority…"
    >
      <List.Section
        title="RAM for Warp & Agents"
        subtitle="Choose other apps to quit and make memory available for coding"
      >
        <List.Item
          title={memory.error ? "Could not measure app memory" : "Warp and agents stay running"}
          subtitle={
            memory.error
              ? errorMessage(memory.error)
              : memory.data
                ? `${formatBytes(memory.data.codingBytes)} estimated coding memory · ${memory.data.codingProcessCount} processes${memory.data.codingIncomplete ? " · incomplete estimate" : ""}`
                : "Install or update Resource Guard to manage RAM"
          }
          icon={Icon.Shield}
          actions={<ActionPanel>{commonActions}</ActionPanel>}
        />
        <List.Item
          title="Quit unused apps below to free memory"
          subtitle="Memory is allocated by macOS as needed; no fixed RAM reservation or automatic app closing"
          icon={Icon.MemoryChip}
          actions={<ActionPanel>{commonActions}</ActionPanel>}
        />
      </List.Section>
      <List.Section
        title="Other Apps Using RAM"
        subtitle="Largest first · estimates include app helpers; exact memory released will vary"
      >
        {(freshMemory?.apps ?? [])
          .filter((app) => !app.protected)
          .map((app) => (
            <List.Item
              key={app.identity.pid}
              title={app.name}
              icon={{ fileIcon: app.path }}
              subtitle={`${app.processCount} processes${app.incomplete ? " · incomplete estimate" : ""}`}
              accessories={[{ text: `${formatBytes(app.bytes)} estimated` }]}
              actions={
                <ActionPanel>
                  <Action
                    title={`Quit ${app.name} to Free RAM`}
                    icon={Icon.XMarkCircle}
                    style={Action.Style.Destructive}
                    onAction={() => quit(app)}
                  />
                  <Action title={`Switch to ${app.name}`} icon={Icon.AppWindow} onAction={() => open(app.path)} />
                  {commonActions}
                </ActionPanel>
              }
            />
          ))}
      </List.Section>
      <List.Section title="Protected Apps" subtitle="Coding sessions and their hosts have no Quit action">
        {(freshMemory?.apps ?? [])
          .filter((app) => app.protected)
          .map((app) => (
            <List.Item
              key={app.identity.pid}
              title={app.name}
              icon={Icon.Shield}
              subtitle={app.reason}
              accessories={[{ text: `${formatBytes(app.bytes)} estimated` }]}
              actions={<ActionPanel>{commonActions}</ActionPanel>}
            />
          ))}
      </List.Section>
      <List.Section title="CPU Priority" subtitle="Secondary to RAM relief · helps when CPU is contested">
        <List.Item
          title={describePriority(priority.data)}
          subtitle={
            priority.data?.errors.length
              ? priority.data.errors.join("; ")
              : priority.data?.installed
                ? `${priority.data.processCount} tracked processes · does not reserve RAM`
                : "Administrator setup required to favor coding processes"
          }
          icon={Icon.Bolt}
          actions={
            <ActionPanel>
              {priority.data?.available ? (
                <Action
                  title={priority.data.enabled ? "Turn off CPU Priority" : "Favor Warp and Agents"}
                  icon={Icon.Bolt}
                  onAction={() => act("Updating CPU priority…", () => toggleResourcePriority(!priority.data?.enabled))}
                />
              ) : (
                <Action.CopyToClipboard title="Copy CPU Priority Setup Command" content={prioritySetupCommand} />
              )}
              {commonActions}
            </ActionPanel>
          }
        />
      </List.Section>
      <List.Section title="Resource Guard" subtitle="Warp and agent sessions keep running">
        <List.Item
          title={describeGuard(status)}
          subtitle={status?.state === "unavailable" ? status.error : "New heavy jobs wait when resources are tight"}
          icon={{
            source: Icon.Shield,
            tintColor: snapshot && !snapshot.blocked && !stale ? Color.Green : Color.Orange,
          }}
          actions={<ActionPanel>{commonActions}</ActionPanel>}
        />
        {sample && !stale && (
          <List.Item
            title={`Memory pressure: ${sample.pressure}`}
            subtitle={`${formatBytes(sample.memory)} RAM · CPU ${sample.cpu.toFixed(0)}%`}
            accessories={[
              { text: `Swap ${formatBytes(sample.swapUsed)}` },
              { text: `In ${formatBytes(sample.swapIn)}/s · Out ${formatBytes(sample.swapOut)}/s` },
            ]}
            actions={<ActionPanel>{commonActions}</ActionPanel>}
          />
        )}
      </List.Section>
      <List.Section title="Guarded Jobs" subtitle="Only commands launched through Resource Guard appear here">
        {(snapshot?.jobs ?? []).map((job) => (
          <List.Item
            key={job.id}
            title={job.name}
            subtitle={job.directory}
            accessories={[
              { text: `${Math.max(0, Math.floor(Date.now() / 1000 - (job.started ?? job.created)))}s` },
              { tag: job.cancelled ? "Cancelling" : job.state },
            ]}
            actions={
              <ActionPanel>
                {job.state !== "unverified" && !job.cancelled && (
                  <Action
                    title={job.state === "queued" ? "Remove Queued Job" : "Cancel Job"}
                    icon={Icon.Stop}
                    style={Action.Style.Destructive}
                    onAction={() => cancel(job, false)}
                  />
                )}
                {job.state === "stopping" && (
                  <Action
                    title="Force Stop Job"
                    icon={Icon.Stop}
                    style={Action.Style.Destructive}
                    onAction={() => cancel(job, true)}
                  />
                )}
                {commonActions}
              </ActionPanel>
            }
          />
        ))}
      </List.Section>
      <List.Section
        title="Observed Processes"
        subtitle="RSS is resident memory, not total footprint; shared pages may overlap"
      >
        {(snapshot?.processes ?? []).map((process) => (
          <List.Item
            key={process.identity.pid}
            title={process.name}
            subtitle={`PID ${process.identity.pid}`}
            accessories={[{ text: process.rss === undefined ? "RSS unavailable" : `${formatBytes(process.rss)} RSS` }]}
            actions={<ActionPanel>{commonActions}</ActionPanel>}
          />
        ))}
      </List.Section>
    </List>
  );
}
