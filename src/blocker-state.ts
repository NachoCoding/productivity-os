import { useCallback } from "react";
import { readCache, useCachedQuery, writeCache } from "./cached-query";
import { BlockerStatus, checkSetup, needsSetup, readStatus, SetupCheck } from "./lib";

const SETUP_KEY = "blocker-setup";
const STATUS_KEY = "blocker-status";
/** How long a view pushed from the dashboard trusts the status the dashboard just read. */
export const PRELOADED_MS = 30_000;

export type BlockerSnapshot = { setup: false } | { setup: true; status: BlockerStatus };

/** The last setup verdict any command saw; undefined until one has checked. */
export const cachedSetup = () => readCache<SetupCheck>(SETUP_KEY);

export async function verifySetup(): Promise<SetupCheck> {
  const result = await checkSetup();
  writeCache(SETUP_KEY, result);
  return result;
}

/** Records that setup is missing, after a helper call was refused for that reason. */
export const forgetSetup = () => writeCache<SetupCheck>(SETUP_KEY, { ok: false });

/** True when setup is done; checks only when no positive verdict is cached. */
export async function setupDone(): Promise<boolean> {
  return cachedSetup()?.ok === true || (await verifySetup()).ok;
}

/**
 * Reads the website status. The setup check runs alongside the read, and only when no positive
 * verdict is cached, a read fails, or `recheckSetup` asks for it.
 */
export async function loadBlocker(recheckSetup = false): Promise<BlockerSnapshot> {
  const pending = recheckSetup || cachedSetup()?.ok !== true ? verifySetup() : undefined;
  const read = await readStatus().then(
    (status) => ({ status }),
    (error: unknown) => ({ error }),
  );
  if ("status" in read) {
    const setup = await pending;
    return setup && !setup.ok ? { setup: false } : { setup: true, status: read.status };
  }
  // sudo refusing without a password, or a missing helper, already means setup is needed.
  let setup = await (pending ?? (needsSetup(read.error) ? undefined : verifySetup()));
  if (!setup) {
    forgetSetup();
    setup = { ok: false };
  }
  if (!setup.ok) return { setup: false };
  throw read.error;
}

export interface BlockerQuery {
  /** Undefined until the first check has finished; cached afterwards. */
  setup: boolean | undefined;
  status: BlockerStatus | undefined;
  error: Error | undefined;
  isLoading: boolean;
  revalidate: () => Promise<unknown>;
  /** Reloads with a fresh setup check, for "Check Again"; resolves to whether setup is done. */
  recheck: () => Promise<boolean>;
}

/**
 * The cached website status, shared by every command. Views render the cached value at once and
 * refresh it in place; pass `freshFor` (e.g. {@link PRELOADED_MS}) when the opener just read it.
 */
export function useBlocker(
  options: { execute?: boolean; freshFor?: number; recheckSetup?: boolean } = {},
): BlockerQuery {
  const { recheckSetup } = options;
  const query = useCachedQuery<BlockerSnapshot>(STATUS_KEY, () => loadBlocker(recheckSetup), {
    execute: options.execute,
    freshFor: options.freshFor,
  });
  const { revalidate } = query;
  const recheck = useCallback(
    async () => (await revalidate({ load: () => loadBlocker(true) }))?.setup === true,
    [revalidate],
  );
  const snapshot = query.data;
  return {
    setup: snapshot?.setup,
    status: snapshot?.setup ? snapshot.status : undefined,
    error: query.error,
    isLoading: query.isLoading,
    revalidate,
    recheck,
  };
}

/** The last website status any command read, if setup was done. */
export function cachedStatus(): BlockerStatus | undefined {
  const snapshot = readCache<BlockerSnapshot>(STATUS_KEY);
  return snapshot?.setup ? snapshot.status : undefined;
}

/** Applies a change this extension just made to the cached status, so the next view opens correct. */
export function updateCachedStatus(update: (status: BlockerStatus) => BlockerStatus): void {
  const snapshot = readCache<BlockerSnapshot>(STATUS_KEY);
  if (snapshot?.setup) writeCache<BlockerSnapshot>(STATUS_KEY, { setup: true, status: update(snapshot.status) });
}
