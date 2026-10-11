import { execFile } from "child_process";

export const HELPER_PATH = "/Library/PrivilegedHelperTools/productivity-os/blocker.sh";
// v4 adds the combined `status` read and the stalled-round review; v3 stays usable until setup reruns.
export const SUPPORTED_HELPER_VERSIONS = ["3", "4"];

export interface HelperResult {
  code: number;
  stdout: string;
  stderr: string;
}

export interface BlockedEntry {
  domain: string;
  tag: string;
}

export interface FocusSession {
  endsAt: number;
  label: string;
}

export interface PomodoroSession {
  phase: "focus" | "shortBreak" | "longBreak" | "ready";
  paused: boolean;
  pauseReason?: "manual" | "away" | "monitor";
  remainingMs: number;
  endsAt: number | null;
  focusMinutes: number;
  shortBreakMinutes: number;
  longBreakMinutes: number;
  roundsPerSet: number;
  completedRounds: number;
  label: string;
  domains: string[];
  /** Helper v4: no progress for 30+ minutes while you were present; the round can be ended by review. */
  stalled?: boolean;
}

/** Everything the website rows show, read under one helper lock (v4) or with three calls (v3). */
export interface BlockerStatus {
  version: string;
  session: FocusSession | null;
  pomodoro: PomodoroSession | null;
  entries: BlockedEntry[];
  /** v4 degraded mode: the policy state is missing or damaged; Run Setup offers a repair. */
  stateDamaged: boolean;
}

export interface UnblockRequest {
  id: string;
  readyAt: number;
  expiresAt: number;
  description: string;
}

/** One reviewed removal. `end-pomodoro` (helper v4, stalled rounds only) must be the only operation. */
export type UnblockOperation =
  | ["remove", string]
  | ["remove-tag", string, string]
  | ["remove-all-with-tag", string]
  | ["remove-everything"]
  | ["end-focus"]
  | ["end-pomodoro"];

export class BlockerError extends Error {
  constructor(
    message: string,
    public readonly code?: string,
  ) {
    super(message);
    this.name = "BlockerError";
  }
}

/** An error's text for a toast or page, without the "Error:" prefix `String(error)` adds. */
export function errorMessage(error: unknown): string {
  const message = (error as { message?: unknown } | null)?.message;
  return (typeof message === "string" ? message : String(error)).replace(/^Error: /, "") || "Unknown error";
}

// sudo refusing without a password (no sudoers rule) or a missing helper both mean setup has not run.
const SETUP_MISSING =
  /a password is required|a terminal is required|command not found|no such file or directory|not in the sudoers|not allowed to/i;

export function helperError(result: HelperResult, fallback: string): BlockerError {
  const message = result.stderr.trim();
  try {
    const error = JSON.parse(message) as { code?: string; message?: string; error?: string };
    return new BlockerError(error.message || error.error || fallback, error.code);
  } catch {
    return new BlockerError(message || fallback, SETUP_MISSING.test(message) ? "SETUP_REQUIRED" : undefined);
  }
}

/** True when an error means the helper is not installed or not allowed to run: show Setup. */
export const needsSetup = (error: unknown) => (error as { code?: unknown } | null)?.code === "SETUP_REQUIRED";

export async function runHelper(args: string[]): Promise<HelperResult> {
  try {
    const { stdout, stderr } = await execFileAsync("/usr/bin/sudo", ["-n", HELPER_PATH, ...args], {
      maxBuffer: 1024 * 1024,
    });
    return { code: 0, stdout, stderr };
  } catch (error) {
    const err = error as { code?: number; stdout?: string; stderr?: string; message?: string };
    return {
      code: typeof err.code === "number" ? err.code : 1,
      stdout: err.stdout ?? "",
      stderr: err.stderr ?? err.message ?? String(error),
    };
  }
}

const invalidResponse = () =>
  new BlockerError("The blocker returned an unexpected response. Run Setup to update it.", "INVALID_RESPONSE");

const isObject = (value: unknown): value is Record<string, unknown> =>
  value !== null && typeof value === "object" && !Array.isArray(value);

function parseJSON(text: string): unknown {
  try {
    return JSON.parse(text);
  } catch {
    throw invalidResponse();
  }
}

/** A non-negative number. Perl can print a number it has pattern-checked as a string, so those count too. */
function count(value: unknown): number {
  const number = typeof value === "string" && /^\d+(\.\d+)?$/.test(value) ? Number(value) : value;
  if (typeof number !== "number" || !Number.isFinite(number) || number < 0) throw invalidResponse();
  return number;
}

function parseSession(value: unknown): FocusSession | null {
  if (value === null) return null;
  if (!isObject(value) || typeof value.label !== "string") throw invalidResponse();
  return { endsAt: count(value.endsAt), label: value.label };
}

const PHASES = ["focus", "shortBreak", "longBreak", "ready"];

function parsePomodoro(value: unknown): PomodoroSession | null {
  if (value === null) return null;
  if (
    !isObject(value) ||
    !PHASES.includes(value.phase as string) ||
    typeof value.paused !== "boolean" ||
    typeof value.label !== "string" ||
    !Array.isArray(value.domains) ||
    !value.domains.every((domain) => typeof domain === "string") ||
    (value.pauseReason !== undefined && typeof value.pauseReason !== "string") ||
    (value.stalled !== undefined && typeof value.stalled !== "boolean")
  ) {
    throw invalidResponse();
  }
  return {
    phase: value.phase as PomodoroSession["phase"],
    paused: value.paused,
    ...(typeof value.pauseReason === "string"
      ? { pauseReason: value.pauseReason as PomodoroSession["pauseReason"] }
      : {}),
    remainingMs: count(value.remainingMs),
    endsAt: value.endsAt === null || value.endsAt === undefined ? null : count(value.endsAt),
    focusMinutes: count(value.focusMinutes),
    shortBreakMinutes: count(value.shortBreakMinutes),
    longBreakMinutes: count(value.longBreakMinutes),
    roundsPerSet: count(value.roundsPerSet),
    completedRounds: count(value.completedRounds),
    label: value.label,
    domains: value.domains as string[],
    stalled: value.stalled === true,
  };
}

function parseEntry(value: unknown): BlockedEntry {
  if (!isObject(value) || typeof value.domain !== "string" || typeof value.tag !== "string") throw invalidResponse();
  return { domain: value.domain, tag: value.tag };
}

/** Parses and validates the v4 `status` reply. */
export function parseStatus(stdout: string): BlockerStatus {
  const value = parseJSON(stdout);
  if (!isObject(value) || !Array.isArray(value.entries)) throw invalidResponse();
  const version = String(value.version ?? "");
  if (!SUPPORTED_HELPER_VERSIONS.includes(version)) {
    throw new BlockerError(`Helper version ${version || "unknown"} is not supported. Run Setup.`, "SETUP_REQUIRED");
  }
  return {
    version,
    session: parseSession(value.session ?? null),
    pomodoro: parsePomodoro(value.pomodoro ?? null),
    entries: value.entries.map(parseEntry),
    stateDamaged: value.stateDamaged === true,
  };
}

/** Session, Pomodoro and blocks in one locked helper call; helper v3 has no `status`, so it takes three. */
export async function readStatus(): Promise<BlockerStatus> {
  const res = await runHelper(["status"]);
  if (res.code === 0) return parseStatus(res.stdout);
  const error = helperError(res, "Could not read website blocking");
  if (!/unknown command/i.test(error.message)) throw error;
  const [session, pomodoro, entries] = await Promise.all([readSession(), readPomodoro(), getBlocked()]);
  return { version: "3", session, pomodoro, entries, stateDamaged: false };
}

export async function readSession(): Promise<FocusSession | null> {
  const res = await runHelper(["session"]);
  if (res.code !== 0) throw helperError(res, "Could not read the focus session");
  return parseSession(parseJSON(res.stdout));
}

export async function readPomodoro(): Promise<PomodoroSession | null> {
  const res = await runHelper(["pomodoro-status"]);
  if (res.code !== 0) throw helperError(res, "Could not read Pomodoro");
  return parsePomodoro(parseJSON(res.stdout));
}

export async function getBlocked(): Promise<BlockedEntry[]> {
  const res = await runHelper(["list"]);
  if (res.code !== 0) throw helperError(res, "Could not read blocked sites");
  return res.stdout
    .split("\n")
    .filter((line) => line.length > 0)
    .map((line) => {
      const tab = line.indexOf("\t");
      return tab === -1 ? { domain: line, tag: "" } : { domain: line.slice(0, tab), tag: line.slice(tab + 1) };
    });
}

export interface SetupCheck {
  ok: boolean;
  version?: string;
}

/** The installed helper answers with a supported version, and its expiry daemon is loaded. */
export async function checkSetup(): Promise<SetupCheck> {
  const [res, daemon] = await Promise.all([
    runHelper(["version"]),
    execFileAsync("/bin/launchctl", ["print", "system/com.productivity-os.expire"], { maxBuffer: 1024 * 1024 }).then(
      () => true,
      () => false,
    ),
  ]);
  const version = res.code === 0 ? res.stdout.trim() : "";
  return { ok: SUPPORTED_HELPER_VERSIONS.includes(version) && daemon, ...(version ? { version } : {}) };
}

/** Helper v4: moves damaged policy state aside and rebuilds a paused recovery round; healthy state is untouched. */
export async function repairState(): Promise<boolean> {
  const res = await runHelper(["repair-state"]);
  if (res.code !== 0) throw helperError(res, "Could not repair the Pomodoro state");
  const value = parseJSON(res.stdout);
  return isObject(value) && value.repaired === true;
}

/**
 * Why the helper refuses website changes right now: a focus session or a Pomodoro focus round that has
 * not finished. `until` is null while the round is paused, since its end is unknown.
 */
export interface FocusLock {
  until: number | null;
}

export function focusLock(
  status: Pick<BlockerStatus, "session" | "pomodoro"> | undefined,
  now = Date.now(),
): FocusLock | undefined {
  if (!status) return undefined;
  const session = status.session && status.session.endsAt > now ? status.session.endsAt : 0;
  const round = status.pomodoro?.phase === "focus" && status.pomodoro.remainingMs > 0 ? status.pomodoro : undefined;
  if (!session && !round) return undefined;
  if (round && (round.paused || round.endsAt === null || round.endsAt <= now)) return { until: null };
  return { until: Math.max(session, round?.endsAt ?? 0) };
}

export const describeLock = (lock: FocusLock) =>
  lock.until === null ? "Locked during focus" : `Locked until ${formatClock(lock.until)}`;

/** The helper also refuses a focus session while any Pomodoro plan exists, breaks included. */
export const canStartFocus = (status: BlockerStatus) => !focusLock(status) && !status.pomodoro;

/** The status after `add-many tag …domains`, so cached views match without another read. */
export function withBlocks(status: BlockerStatus, domains: string[], tag: string): BlockerStatus {
  const tags = new Map(status.entries.map((entry) => [entry.domain, new Set(entry.tag.split(",").filter(Boolean))]));
  for (const domain of domains) tags.set(domain, new Set([...(tags.get(domain) ?? []), tag]));
  const entries = [...tags]
    .sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0))
    .map(([domain, set]) => ({ domain, tag: [...set].sort().join(",") }));
  return { ...status, entries };
}

/** The status after a confirmed unblock review, mirroring the helper's removal rules. */
export function withoutBlocks(status: BlockerStatus, operations: UnblockOperation[]): BlockerStatus {
  const removes = (domain: string, tag: string) =>
    operations.some(
      ([command, first, second]) =>
        command === "remove-everything" ||
        (command === "remove" && first === domain) ||
        (command === "remove-tag" && first === domain && second === tag) ||
        (command === "remove-all-with-tag" && first === tag) ||
        (command === "end-focus" && tag === "focus"),
    );
  const commands = operations.map(([command]) => command);
  const entries = status.entries.flatMap(({ domain, tag }) => {
    const kept = tag.split(",").filter((name) => name && !removes(domain, name));
    return kept.length ? [{ domain, tag: kept.join(",") }] : [];
  });
  return {
    ...status,
    entries,
    session: commands.includes("end-focus") || commands.includes("remove-everything") ? null : status.session,
    pomodoro: commands.includes("end-pomodoro") ? null : status.pomodoro,
  };
}

export function describePomodoro(session: PomodoroSession | null | undefined): string {
  if (!session) return "25-minute focus · 5-minute breaks";
  if (session.phase === "ready") return "Ready for the next round";
  const phase = session.phase === "focus" ? "Focus" : session.phase === "longBreak" ? "Long break" : "Break";
  // A running phase counts down from its end time, so a cached reading stays current.
  const remaining =
    !session.paused && session.endsAt !== null ? Math.max(0, session.endsAt - Date.now()) : session.remainingMs;
  return `${phase}${session.stalled ? " stalled" : session.paused ? " paused" : ""} · ${formatRemaining(remaining)} left`;
}

export async function requestUnblock(operations: UnblockOperation[]): Promise<UnblockRequest> {
  if (!operations.length) throw new Error("Choose the sites to unblock first.");
  if (operations.length > 1 && operations.some(([command]) => command === "end-pomodoro")) {
    throw new Error("End the stalled round in a review of its own.");
  }
  const args = operations.length === 1 ? operations[0] : ["batch", JSON.stringify(operations)];
  const result = await runHelper(["request-unblock", ...args]);
  if (result.code !== 0) throw helperError(result, "Could not request an unblock");
  const request = parseJSON(result.stdout) as UnblockRequest;
  if (!request?.id || !Number.isFinite(request.readyAt) || !Number.isFinite(request.expiresAt)) {
    throw new Error("The blocker returned an invalid request. Run Setup to update it.");
  }
  return request;
}

export async function confirmUnblock(id: string, reason: string): Promise<void> {
  if (!reason.trim()) throw new Error("Enter a short reason before unblocking.");
  const result = await runHelper(["confirm-unblock", id, reason.trim()]);
  if (result.code !== 0) throw helperError(result, "Could not confirm the unblock");
}

// Must stay in sync with the regex in assets/blocker.sh.
export const domainRegex = /^(?=.{1,253}$)([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$/;

/**
 * The hostnames a block for `domain` must cover. Hosts entries match exact names, and most
 * sites serve from both the bare domain and its `www` subdomain, so blocking one without the
 * other leaves the site reachable. Returns the bare name first, then the `www` variant,
 * dropping any variant that is not a valid hostname.
 */
export function hostVariants(domain: string): string[] {
  const bare = domain.replace(/^www\./, "");
  return [...new Set([bare, `www.${bare}`, domain])].filter((name) => domainRegex.test(name));
}

/**
 * Unblocking a site removes every block on its bare and `www` hostnames in one review: browsers move between
 * the two (facebook.com redirects to www.facebook.com), so unblocking only the selected name looked broken.
 */
export function siteUnblockOperations(domain: string, entries: BlockedEntry[]): UnblockOperation[] {
  const blocked = new Set(entries.map((entry) => entry.domain));
  const names = hostVariants(domain).filter((name) => blocked.has(name));
  return (names.length ? names : [domain]).map((name): UnblockOperation => ["remove", name]);
}

/**
 * Unblocking a tag (a preset such as Social) also lifts the Pomodoro's leftover block on the same hostnames.
 * A Pomodoro blocks its sites under its own `pomodoro` tag and keeps them after the round, so removing only
 * the preset tag left every one of those sites blocked. Manual and other preset blocks stay.
 */
export function tagUnblockOperations(tag: string, entries: BlockedEntry[]): UnblockOperation[] {
  if (tag === "focus") return [["end-focus"]];
  const operations: UnblockOperation[] = [["remove-all-with-tag", tag]];
  if (tag === "pomodoro") return operations;
  for (const { domain, tag: tags } of entries) {
    const names = tags.split(",");
    if (names.includes(tag) && names.includes("pomodoro")) operations.push(["remove-tag", domain, "pomodoro"]);
  }
  return operations;
}

/** Hostnames the operations target that another block (for example a manual one) keeps blocked. */
export function stillBlocked(status: BlockerStatus, operations: UnblockOperation[]): BlockedEntry[] {
  const after = new Map(withoutBlocks(status, operations).entries.map((entry) => [entry.domain, entry]));
  const targeted = (domain: string, tags: string[]) =>
    operations.some(([command, first]) =>
      command === "remove" || command === "remove-tag"
        ? first === domain
        : command === "remove-all-with-tag" && tags.includes(first ?? ""),
    );
  return status.entries.flatMap((entry) => {
    const left = after.get(entry.domain);
    return left && targeted(entry.domain, entry.tag.split(",")) ? [left] : [];
  });
}

export function normalizeDomain(input: string): string {
  const value = input.trim().toLowerCase();
  // Only bare hostnames and HTTP(S) URLs are accepted; "ftp://x" must not become the hostname "ftp".
  if (!value || (/^[a-z][a-z0-9+.-]*:\/\//.test(value) && !/^https?:\/\//.test(value))) return "";
  try {
    const url = new URL(/^https?:\/\//.test(value) ? value : `https://${value}`);
    if (!["http:", "https:"].includes(url.protocol) || url.username || url.password) return "";
    return url.hostname.replace(/\.$/, "");
  } catch {
    return "";
  }
}

export const MAX_FOCUS_MINUTES = 1440;

/** A whole number of minutes from 1 to 24 hours, or undefined. */
export function parseFocusMinutes(value: string): number | undefined {
  const minutes = /^\d+$/.test(value.trim()) ? Number(value.trim()) : NaN;
  return Number.isInteger(minutes) && minutes >= 1 && minutes <= MAX_FOCUS_MINUTES ? minutes : undefined;
}

/** Starts a locked one-shot focus session; unfinished commitments cannot be replaced. */
export async function startFocusSession(minutes: number, label: string, domains: string[]): Promise<FocusSession> {
  const res = await runHelper(["start-focus", String(minutes), label, ...domains]);
  if (res.code !== 0) throw helperError(res, "Could not start session");
  const session = parseSession(parseJSON(res.stdout));
  if (!session) throw invalidResponse();
  return session;
}

/** The status after `start-focus`: the session, and focus blocks on exactly `domains`. */
export function withFocusSession(status: BlockerStatus, session: FocusSession, domains: string[]): BlockerStatus {
  return { ...withBlocks(withoutBlocks(status, [["end-focus"]]), domains, "focus"), session };
}

export const formatClock = (time: number) =>
  new Date(time).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" });

export function formatRemaining(ms: number): string {
  const totalMinutes = Math.max(0, Math.ceil(ms / 60000));
  if (totalMinutes < 60) return `${totalMinutes}m`;
  const hours = Math.floor(totalMinutes / 60);
  const minutes = totalMinutes % 60;
  return minutes === 0 ? `${hours}h` : `${hours}h ${minutes}m`;
}

const execFileAsync = (cmd: string, args: string[], opts: { maxBuffer: number }) =>
  new Promise<{ stdout: string; stderr: string }>((resolve, reject) => {
    execFile(cmd, args, { ...opts, timeout: 15000 }, (error, stdout, stderr) => {
      if (error) {
        Object.assign(error, { stdout, stderr });
        reject(error);
      } else {
        resolve({ stdout, stderr });
      }
    });
  });

export async function blockDomains(domains: string[], tag: string): Promise<void> {
  const res = await runHelper(["add-many", tag, ...domains]);
  if (res.code !== 0) throw helperError(res, `Could not block ${domains.join(", ")}`);
}
