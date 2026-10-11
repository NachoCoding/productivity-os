import { Action, ActionPanel, closeMainWindow, Form, Icon, popToRoot, showHUD, showToast, Toast } from "@raycast/api";
import { useRef, useState } from "react";
import { forgetSetup, PRELOADED_MS, updateCachedStatus, useBlocker } from "./blocker-state";
import {
  describeLock,
  errorMessage,
  focusLock,
  formatClock,
  MAX_FOCUS_MINUTES,
  needsSetup,
  parseFocusMinutes,
  startFocusSession,
  withFocusSession,
} from "./lib";
import { presets } from "./presets";
import SetupInstructions from "./show-setup";

const DURATIONS = [15, 30, 45, 60, 90];

export default function StartFocusSession() {
  return <StartFocusSessionForm />;
}

interface FormValues {
  preset: string;
  duration: string;
  customMinutes?: string;
}

/** `preloaded`: the opener has just read the status, so it is not read again on open. */
export function StartFocusSessionForm(props: { preselectedDomains?: string[]; preloaded?: boolean }) {
  const blocker = useBlocker({ freshFor: props.preloaded ? PRELOADED_MS : undefined });
  const submitting = useRef(false);
  const [busy, setBusy] = useState(false);
  const [duration, setDuration] = useState("30");
  const [presetError, setPresetError] = useState<string | undefined>();
  const [minutesError, setMinutesError] = useState<string | undefined>();

  if (blocker.setup === false) return <SetupInstructions onCheckAgain={blocker.recheck} />;
  if (blocker.setup === undefined && blocker.isLoading) return <Form isLoading />;

  const status = blocker.status;
  const entries = status?.entries;
  const lock = focusLock(status);
  // The helper refuses both; say so up front instead of after a submit.
  const blockedBy = lock
    ? `${describeLock(lock)}. A new focus session can start after the current one ends.`
    : status?.pomodoro
      ? "A Pomodoro is running. Stop it in Pomodoro before starting a different timer."
      : undefined;
  const preselected = props.preselectedDomains;
  const defaultPreset = preselected ? "custom" : presets[0].name;
  const customTitle = preselected
    ? `Selected site${preselected.length === 1 ? "" : "s"} (${preselected.length})`
    : `Currently blocked sites${entries ? ` (${entries.length})` : ""}`;

  async function handleSubmit(values: FormValues) {
    if (submitting.current) return;
    setPresetError(undefined);
    setMinutesError(undefined);

    let domains: string[];
    let label: string;
    if (values.preset === "custom") {
      // A session over stale blocks could re-block a site that was just unblocked, so wait for a fresh read.
      if (!preselected && (blocker.isLoading || blocker.error || !entries)) {
        setPresetError("Wait for blocked sites to load, or reopen this command if loading failed.");
        return;
      }
      domains = preselected ?? (entries ?? []).map((entry) => entry.domain);
      label = "Custom";
      if (domains.length === 0) {
        setPresetError("Nothing is currently blocked — pick a preset instead.");
        return;
      }
    } else {
      const preset = presets.find((p) => p.name === values.preset);
      if (!preset) {
        setPresetError("Pick a preset.");
        return;
      }
      domains = preset.domains;
      label = preset.title;
    }

    const minutes = parseFocusMinutes(values.duration === "custom" ? (values.customMinutes ?? "") : values.duration);
    if (minutes === undefined) {
      setMinutesError(`Enter a whole number of minutes between 1 and ${MAX_FOCUS_MINUTES}.`);
      return;
    }

    submitting.current = true;
    setBusy(true);
    try {
      const session = await startFocusSession(minutes, `${label} focus`, domains);
      updateCachedStatus((current) => withFocusSession(current, session, domains));
      await closeMainWindow();
      await showHUD(`🔒 Focus until ${formatClock(session.endsAt)} (${label}, ${minutes} min)`);
      await popToRoot();
    } catch (error) {
      if (needsSetup(error)) {
        forgetSetup();
        void blocker.recheck();
      }
      await showToast({ style: Toast.Style.Failure, title: "Could not start session", message: errorMessage(error) });
    } finally {
      submitting.current = false;
      setBusy(false);
    }
  }

  return (
    <Form
      isLoading={busy || blocker.isLoading}
      actions={
        <ActionPanel>
          <Action.SubmitForm title="Start Focus Session" icon={Icon.Play} onSubmit={handleSubmit} />
        </ActionPanel>
      }
    >
      {blockedBy && <Form.Description title="Not Available Now" text={blockedBy} />}
      <Form.Dropdown
        id="preset"
        title="Block"
        defaultValue={defaultPreset}
        error={presetError}
        onChange={() => setPresetError(undefined)}
        info="Existing manual and preset blocks stay blocked after the session. An unfinished focus session cannot be shortened or replaced. Sites cannot be unblocked before it ends."
      >
        {presets.map((preset) => (
          <Form.Dropdown.Item
            key={preset.name}
            value={preset.name}
            title={`${preset.title} (${preset.domains.length} sites)`}
            icon={preset.icon}
          />
        ))}
        <Form.Dropdown.Item value="custom" title={customTitle} icon="🔒" />
      </Form.Dropdown>
      <Form.Dropdown
        id="duration"
        title="Duration"
        value={duration}
        onChange={(value) => {
          setDuration(value);
          setMinutesError(undefined);
        }}
        error={duration === "custom" ? undefined : minutesError}
      >
        {DURATIONS.map((minutes) => (
          <Form.Dropdown.Item key={minutes} value={String(minutes)} title={`${minutes} minutes`} icon={Icon.Clock} />
        ))}
        <Form.Dropdown.Item value="custom" title="Custom…" icon={Icon.Pencil} />
      </Form.Dropdown>
      {duration === "custom" && (
        <Form.TextField
          id="customMinutes"
          title="Custom minutes"
          placeholder="e.g. 20"
          autoFocus
          error={minutesError}
          onChange={() => setMinutesError(undefined)}
          info={`Whole minutes, 1–${MAX_FOCUS_MINUTES} (24 hours).`}
        />
      )}
    </Form>
  );
}
