/** Whole minutes from `now` until `target`, rounded up, or undefined when `target` is not in the future. */
export function minutesUntil(target: Date, now = new Date()): number | undefined {
  return target > now ? Math.ceil((target.getTime() - now.getTime()) / 60000) : undefined;
}

/** A duration field: empty means 0 (no time limit), and anything other than a whole number is invalid (null). */
export function parseWholeNumber(value: string | undefined): number | null {
  const text = (value ?? "").trim();
  if (text === "") return 0;
  return /^\d+$/.test(text) ? parseInt(text, 10) : null;
}

export function formatDateTime(date: Date): string {
  return date.toLocaleString([], { dateStyle: "medium", timeStyle: "short" });
}

/** Formats Amphetamine's `session time remaining` (seconds) as `HH:MMh` or `MM:SSmin`. */
export function formatRemainingSeconds(totalSeconds: number): string {
  const whole = Math.max(0, Math.floor(totalSeconds));
  const pad = (value: number) => String(value).padStart(2, "0");
  const hours = Math.floor(whole / 3600);
  const minutes = Math.floor((whole % 3600) / 60);
  return hours > 0 ? `${pad(hours)}:${pad(minutes)}h` : `${pad(minutes)}:${pad(whole % 60)}min`;
}

// Amphetamine answers `session time remaining` with seconds, or one of these codes.
const REMAINING_STATES: Record<string, string> = {
  "0": "Your current session has no time limit",
  "-1": "Your session is Trigger-based",
  "-2": "Your session is app-based (while an app is running) or date-based (until a set time)",
  "-3": "There is no session running",
};

/** Explains Amphetamine's `session time remaining` answer in a sentence. */
export function describeRemaining(remaining: string): string {
  const value = remaining.trim();
  if (REMAINING_STATES[value]) return REMAINING_STATES[value];
  return `Remaining time: ${Number(value) > 0 ? formatRemainingSeconds(Number(value)) : value}`;
}

/** Renders minutes as "1h 30m", "2h", "45m" or, from a day on, "1d 2h 5m". */
export function formatShortDuration(totalMinutes: number): string {
  const days = Math.floor(totalMinutes / 1440);
  const hours = Math.floor((totalMinutes % 1440) / 60);
  const minutes = totalMinutes % 60;
  const parts = [days && `${days}d`, hours && `${hours}h`, minutes && `${minutes}m`].filter(Boolean);
  return parts.length ? parts.join(" ") : "0m";
}

/** Renders minutes as the non-zero weeks, days, hours and minutes, e.g. "1 day, 2 hours, and 5 minutes". */
export function formatDurationBreakdown(totalMinutes: number): string {
  let rest = Math.max(0, Math.floor(totalMinutes));
  const parts: string[] = [];
  for (const [unit, size] of [
    ["week", 7 * 24 * 60],
    ["day", 24 * 60],
    ["hour", 60],
    ["minute", 1],
  ] as const) {
    const count = Math.floor(rest / size);
    rest %= size;
    if (count) parts.push(`${count} ${unit}${count === 1 ? "" : "s"}`);
  }
  if (parts.length === 0) return "less than a minute";
  if (parts.length <= 2) return parts.join(" and ");
  return `${parts.slice(0, -1).join(", ")}, and ${parts[parts.length - 1]}`;
}
