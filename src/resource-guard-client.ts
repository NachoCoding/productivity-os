import { environment } from "@raycast/api";
import { execFile } from "child_process";
import { existsSync } from "fs";
import { homedir } from "os";
import { join } from "path";
import { errorMessage } from "./lib";

export const guardBinary = join(homedir(), "Library/Application Support/Productivity OS/Resource Guard/resource-guard");
export const priorityBinary = "/Library/PrivilegedHelperTools/productivity-os/resource-priority";
const quote = (value: string) => "'" + value.replace(/'/g, "'\\''") + "'";
export const prioritySetupCommand = `sudo /bin/bash ${quote(join(environment.assetsPath, "setup-resource-priority.sh"))} install`;

export interface PriorityStatus {
  installed: boolean;
  available: boolean;
  enabled: boolean | null;
  processCount: number;
  errors: string[];
  checkedAt?: number | null;
}

export async function resourcePriority(): Promise<PriorityStatus> {
  if (!existsSync(priorityBinary))
    return { installed: false, available: false, enabled: false, processCount: 0, errors: [] };
  try {
    const data = parsePriority(await execute("/usr/bin/sudo", ["-n", priorityBinary, "status"]));
    return { ...data, installed: true, available: true };
  } catch (error) {
    return { installed: true, available: false, enabled: null, processCount: 0, errors: [errorMessage(error)] };
  }
}

export function describePriority(status: PriorityStatus | undefined): string {
  if (!status) return "Reading CPU priority…";
  if (status.installed && !status.available) return "CPU Priority: Status Unavailable";
  if (status.enabled && (!status.checkedAt || Date.now() / 1000 - status.checkedAt > 20))
    return "CPU Priority: Monitoring Stale";
  if (status.errors.length) return "CPU Priority: Needs Attention";
  return status.enabled ? "Warp & Agents: CPU Priority On" : "Warp & Agents: CPU Priority Off";
}

function parsePriority(output: string): Omit<PriorityStatus, "installed" | "available"> {
  const value: unknown = JSON.parse(output);
  if (
    !object(value) ||
    typeof value.enabled !== "boolean" ||
    !nonnegative(value.processCount) ||
    !Array.isArray(value.errors) ||
    !value.errors.every((error) => typeof error === "string") ||
    !(value.checkedAt == null || nonnegative(value.checkedAt))
  )
    throw new Error("Invalid CPU priority response; repair the helper");
  return value as unknown as Omit<PriorityStatus, "installed" | "available">;
}

export function toggleResourcePriority(enabled: boolean): Promise<string> {
  return execute("/usr/bin/sudo", ["-n", priorityBinary, enabled ? "enable" : "disable"]).then((output) => {
    const result = parsePriority(output);
    if (result.errors?.length) throw new Error(result.errors.join("; "));
    return enabled
      ? "CPU scheduling priority enabled; this does not reserve RAM"
      : "CPU priority disabled; tracked process priorities restored";
  });
}

export interface GuardJob {
  id: string;
  name: string;
  directory: string;
  state: "queued" | "admitted" | "running" | "stopping" | "unverified";
  created: number;
  started?: number;
  cancelled: boolean;
}

export interface GuardSnapshot {
  version: number;
  limit: number;
  blocked: boolean;
  reason: string;
  sampleAge: number | null;
  sample: {
    pressure: string;
    cpu: number;
    swapIn: number;
    swapOut: number;
    swapUsed: number;
    memory: number;
  } | null;
  jobs: GuardJob[];
  processes: { identity: { pid: number }; name: string; rss?: number }[];
}

export interface MemoryApp {
  identity: { pid: number; seconds: number; micros: number };
  bundleID: string;
  path: string;
  name: string;
  bytes: number;
  processCount: number;
  incomplete: boolean;
  protected: boolean;
  reason?: string;
}

export interface MemoryReport {
  apps: MemoryApp[];
  codingBytes: number;
  codingProcessCount: number;
  codingIncomplete: boolean;
  measuredAt: number;
}

export async function resourceMemory(): Promise<MemoryReport | undefined> {
  if (!existsSync(guardBinary)) return undefined;
  const report: unknown = JSON.parse(await execute(guardBinary, ["apps"]));
  if (
    !object(report) ||
    !nonnegative(report.codingBytes) ||
    !nonnegative(report.codingProcessCount) ||
    typeof report.codingIncomplete !== "boolean" ||
    !nonnegative(report.measuredAt) ||
    !Array.isArray(report.apps) ||
    !report.apps.every(
      (app) =>
        object(app) &&
        validIdentity(app.identity) &&
        typeof app.bundleID === "string" &&
        typeof app.path === "string" &&
        app.path.startsWith("/") &&
        typeof app.name === "string" &&
        nonnegative(app.bytes) &&
        nonnegative(app.processCount) &&
        typeof app.protected === "boolean" &&
        typeof app.incomplete === "boolean",
    )
  ) {
    throw new Error("Invalid app memory response; update Resource Guard");
  }
  return report as unknown as MemoryReport;
}

const object = (value: unknown): value is Record<string, unknown> =>
  value !== null && typeof value === "object" && !Array.isArray(value);
const nonnegative = (value: unknown): value is number =>
  typeof value === "number" && Number.isFinite(value) && value >= 0;
function validIdentity(value: unknown): boolean {
  return (
    object(value) &&
    nonnegative(value.pid) &&
    value.pid > 0 &&
    Number.isInteger(value.pid) &&
    nonnegative(value.seconds) &&
    nonnegative(value.micros)
  );
}

function validSnapshot(value: unknown): value is GuardSnapshot {
  if (
    !object(value) ||
    value.version !== 1 ||
    ![1, 2].includes(value.limit as number) ||
    typeof value.blocked !== "boolean" ||
    typeof value.reason !== "string" ||
    !(value.sampleAge === null || nonnegative(value.sampleAge)) ||
    !Array.isArray(value.jobs) ||
    !Array.isArray(value.processes)
  )
    return false;
  if (
    value.sample !== null &&
    (!object(value.sample) ||
      typeof value.sample.pressure !== "string" ||
      !["cpu", "swapIn", "swapOut", "swapUsed", "memory"].every((key) =>
        nonnegative((value.sample as Record<string, unknown>)[key]),
      ))
  )
    return false;
  return (
    value.jobs.every(
      (job) =>
        object(job) &&
        typeof job.id === "string" &&
        typeof job.name === "string" &&
        typeof job.directory === "string" &&
        ["queued", "admitted", "running", "stopping", "unverified"].includes(job.state as string) &&
        nonnegative(job.created) &&
        (job.started === undefined || nonnegative(job.started)) &&
        typeof job.cancelled === "boolean",
    ) &&
    value.processes.every(
      (process) =>
        object(process) &&
        object(process.identity) &&
        nonnegative(process.identity.pid) &&
        typeof process.name === "string" &&
        (process.rss === undefined || nonnegative(process.rss)),
    )
  );
}

export function quitMemoryApp(app: MemoryApp): Promise<string> {
  return execute(guardBinary, [
    "quit-app",
    String(app.identity.pid),
    String(app.identity.seconds),
    String(app.identity.micros),
    app.bundleID,
  ]);
}

export type GuardStatus =
  { state: "missing" } | { state: "unavailable"; error: string } | { state: "ready"; snapshot: GuardSnapshot };

function execute(binary: string, args: string[], timeout = 5000): Promise<string> {
  return new Promise((resolve, reject) => {
    execFile(binary, args, { timeout, maxBuffer: 1024 * 1024 }, (error, stdout, stderr) => {
      if (error) reject(new Error(stderr.trim() || error.message));
      else resolve(stdout.trim());
    });
  });
}

export async function resourceGuardStatus(): Promise<GuardStatus> {
  if (!existsSync(guardBinary)) return { state: "missing" };
  try {
    const snapshot: unknown = JSON.parse(await execute(guardBinary, ["status", "--json"]));
    if (!validSnapshot(snapshot)) {
      throw new Error("Unsupported Resource Guard response; reinstall the helper");
    }
    return { state: "ready", snapshot };
  } catch (error) {
    return { state: "unavailable", error: errorMessage(error) };
  }
}

export function describeGuard(status: GuardStatus | undefined): string {
  if (!status) return "Loading…";
  if (status.state === "missing") return "Not installed";
  if (status.state === "unavailable") return "Monitoring unavailable";
  const { snapshot } = status;
  if (!snapshot.sample || snapshot.sampleAge === null || snapshot.sampleAge > 10) return "Measurements unavailable";
  if (snapshot.blocked) return snapshot.reason;
  const running = snapshot.jobs.filter((job) => job.state !== "queued").length;
  const queued = snapshot.jobs.filter((job) => job.state === "queued").length;
  return `${running}/${snapshot.limit} running · ${queued} waiting`;
}

export function installResourceGuard(): Promise<string> {
  return execute("/bin/bash", [join(environment.assetsPath, "setup-resource-guard.sh"), "install"], 30000);
}

export function setGuardLimit(limit: number): Promise<string> {
  return execute(guardBinary, ["limit", String(limit)]);
}

export function cancelGuardJob(id: string, force = false): Promise<string> {
  return execute(guardBinary, ["cancel", id, ...(force ? ["--force"] : [])]);
}

export function formatBytes(bytes: number): string {
  return bytes >= 1024 ** 3 ? `${(bytes / 1024 ** 3).toFixed(1)} GB` : `${(bytes / 1024 ** 2).toFixed(1)} MB`;
}
