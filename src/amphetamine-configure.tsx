import { Action, ActionPanel, Form, Icon, LocalStorage, popToRoot, showToast, Toast } from "@raycast/api";
import { useEffect, useRef, useState } from "react";
import { keepAwake } from "./amphetamine";
import { formatDateTime, minutesUntil, parseWholeNumber } from "./amphetamine-time";

type Unit = "minutes" | "hours";
type SessionType = "duration" | "time";

const DURATION_KEY = "amphetamine-duration";
const UNIT_KEY = "amphetamine-unit";
const FUTURE_TIME = "Choose a future date and time.";

/** The next whole minute: the earliest time a session can run until. */
function nextMinute(): Date {
  const date = new Date();
  date.setMinutes(date.getMinutes() + 1, 0, 0);
  return date;
}

export default function ConfigureNewSession() {
  const [sessionType, setSessionType] = useState<SessionType>("duration");
  const [unit, setUnit] = useState<Unit>("minutes");
  const [duration, setDuration] = useState("30");
  const [target, setTarget] = useState<Date | null>(null);
  const submitting = useRef(false);
  const [busy, setBusy] = useState(false);
  const [durationError, setDurationError] = useState<string>();
  const [targetError, setTargetError] = useState<string>();
  const [earliest, setEarliest] = useState(nextMinute);
  const [isLoading, setIsLoading] = useState(true);

  // The last duration and unit are remembered between runs.
  useEffect(() => {
    let mounted = true;
    Promise.all([LocalStorage.getItem<string>(DURATION_KEY), LocalStorage.getItem<string>(UNIT_KEY)])
      .then(([storedDuration, storedUnit]) => {
        if (!mounted) return;
        if (storedDuration !== undefined) setDuration(storedDuration);
        if (storedUnit === "minutes" || storedUnit === "hours") setUnit(storedUnit);
      })
      .catch(() => undefined)
      .finally(() => mounted && setIsLoading(false));
    return () => {
      mounted = false;
    };
  }, []);

  useEffect(() => {
    if (sessionType !== "time") return;
    setEarliest(nextMinute());
    const timer = setInterval(() => setEarliest(nextMinute()), 60_000);
    return () => clearInterval(timer);
  }, [sessionType]);

  function changeUnit(next: Unit) {
    // The dropdown reports its initial value on mount; storing that would overwrite the remembered unit.
    if (next === unit) return;
    setUnit(next);
    void LocalStorage.setItem(UNIT_KEY, next);
  }

  async function submit() {
    if (submitting.current || isLoading) return;
    let minutes: number;
    if (sessionType === "time") {
      const until = target ? minutesUntil(target) : undefined;
      if (!until) {
        setTargetError(FUTURE_TIME);
        await showToast({ style: Toast.Style.Failure, title: "Could not start keep awake", message: FUTURE_TIME });
        return;
      }
      minutes = until;
    } else {
      const amount = parseWholeNumber(duration);
      if (amount === null) {
        setDurationError("Enter a whole number of minutes or hours.");
        await showToast({
          style: Toast.Style.Failure,
          title: "Could not start keep awake",
          message: "The duration must be a whole number",
        });
        return;
      }
      // Empty or zero means no time limit, as in every keep-awake command.
      minutes = unit === "hours" ? amount * 60 : amount;
    }
    submitting.current = true;
    setBusy(true);
    try {
      if (await keepAwake(minutes)) await popToRoot();
    } finally {
      submitting.current = false;
      setBusy(false);
    }
  }

  return (
    <Form
      isLoading={isLoading || busy}
      navigationTitle="Configure Keep Awake"
      actions={
        <ActionPanel>
          <Action.SubmitForm title="Start Keep Awake" icon={Icon.Play} onSubmit={submit} />
          {sessionType === "duration" && (
            <>
              <Action
                title="Select Hours"
                icon={Icon.Clock}
                shortcut={{ modifiers: ["cmd"], key: "h" }}
                onAction={() => changeUnit("hours")}
              />
              <Action
                title="Select Minutes"
                icon={Icon.Clock}
                shortcut={{ modifiers: ["cmd"], key: "m" }}
                onAction={() => changeUnit("minutes")}
              />
            </>
          )}
        </ActionPanel>
      }
    >
      <Form.Dropdown
        id="sessionType"
        title="Session Type"
        value={sessionType}
        storeValue
        onChange={(value) => setSessionType(value as SessionType)}
      >
        <Form.Dropdown.Item value="duration" title="For Duration" />
        <Form.Dropdown.Item value="time" title="Until Time" />
      </Form.Dropdown>
      {sessionType === "duration" ? (
        <>
          <Form.TextField
            id="duration"
            title={`Duration (in ${unit})`}
            info="Leave empty for no time limit. A new session replaces a running one."
            value={duration}
            error={durationError}
            onChange={(value) => {
              setDuration(value);
              setDurationError(undefined);
              void LocalStorage.setItem(DURATION_KEY, value);
            }}
          />
          <Form.Dropdown id="unit" title="Unit" value={unit} onChange={(value) => changeUnit(value as Unit)}>
            <Form.Dropdown.Item value="minutes" title="minutes" />
            <Form.Dropdown.Item value="hours" title="hours" />
          </Form.Dropdown>
        </>
      ) : (
        <Form.DatePicker
          id="target"
          title="Until"
          type={Form.DatePicker.Type.DateTime}
          min={earliest}
          value={target}
          error={targetError}
          info={target && minutesUntil(target) ? `Starts a session until ${formatDateTime(target)}.` : FUTURE_TIME}
          onChange={(value) => {
            setTarget(value);
            setTargetError(value && minutesUntil(value) ? undefined : FUTURE_TIME);
          }}
        />
      )}
    </Form>
  );
}
