import { Cache } from "@raycast/api";
import { useCallback, useEffect, useMemo, useRef, useState, useSyncExternalStore } from "react";

// One cache for every command of the extension: each view opens with whatever any of them read last,
// so the dashboard, the menu bar and the website views share one status.
const cache = new Cache();
// Part of every key, so a changed value shape is never read back as the new one.
const SHAPE = "1";

interface Entry<T> {
  value: T;
  savedAt: number;
}

function load(key: string): string | undefined {
  try {
    return cache.get(`${key}@${SHAPE}`);
  } catch {
    return undefined;
  }
}

function parse<T>(raw: string | undefined): Entry<T> | undefined {
  if (raw === undefined) return undefined;
  try {
    const entry = JSON.parse(raw) as Entry<T> | null;
    return entry && typeof entry.savedAt === "number" ? entry : undefined;
  } catch {
    return undefined;
  }
}

export function readCache<T>(key: string): T | undefined {
  return parse<T>(load(key))?.value;
}

export function writeCache<T>(key: string, value: T): void {
  try {
    cache.set(`${key}@${SHAPE}`, JSON.stringify({ value, savedAt: Date.now() }));
  } catch {
    // An unwritable cache only costs speed.
  }
}

const subscribe = (onChange: () => void) => cache.subscribe(() => onChange());

export interface QueryOptions {
  /** Load on mount (default true). The cached value still renders when false. */
  execute?: boolean;
  /** Skip the mount load while the cached value is younger than this many milliseconds. */
  freshFor?: number;
  onError?: (error: Error) => void;
}

export interface Query<T> {
  data: T | undefined;
  error: Error | undefined;
  /** A visible load is running: the first one, or one started without `silent`. */
  isLoading: boolean;
  /** Reloads and returns the new value; `silent` loads leave `isLoading` alone (polling). */
  revalidate: (options?: { silent?: boolean; load?: () => Promise<T> }) => Promise<T | undefined>;
  /** Sets the value now, for example the state a toggle reported, and drops older loads still running. */
  mutate: (value: T) => void;
}

/**
 * Like `useCachedPromise`, but keyed by name so every command shares the value, without failure
 * toasts (each view shows its own errors), and with silent reloads for polling. Only the newest
 * load's result is kept.
 */
export function useCachedQuery<T>(key: string, fetch: () => Promise<T>, options: QueryOptions = {}): Query<T> {
  const raw = useSyncExternalStore(subscribe, () => load(key));
  const entry = useMemo(() => parse<T>(raw), [raw]);
  const execute = options.execute !== false;
  const [fresh] = useState(
    () => options.freshFor !== undefined && !!entry && Date.now() - entry.savedAt < options.freshFor,
  );
  const [state, setState] = useState<{ isLoading: boolean; error?: Error }>({ isLoading: execute && !fresh });
  const latest = useRef({ fetch, onError: options.onError });
  latest.current = { fetch, onError: options.onError };
  const calls = useRef(0);

  const revalidate = useCallback(
    async ({ silent = false, load: override }: { silent?: boolean; load?: () => Promise<T> } = {}) => {
      const call = ++calls.current;
      if (!silent) setState((previous) => (previous.isLoading ? previous : { ...previous, isLoading: true }));
      try {
        const value = await (override ?? latest.current.fetch)();
        if (call !== calls.current) return undefined;
        writeCache(key, value);
        setState({ isLoading: false });
        return value;
      } catch (caught) {
        if (call !== calls.current) return undefined;
        const error = caught instanceof Error ? caught : new Error(String(caught));
        setState({ isLoading: false, error });
        latest.current.onError?.(error);
        return undefined;
      }
    },
    [key],
  );

  useEffect(() => {
    if (execute && !fresh) void revalidate();
  }, [execute, fresh, revalidate]);

  const mutate = useCallback(
    (value: T) => {
      calls.current++;
      writeCache(key, value);
      setState({ isLoading: false });
    },
    [key],
  );

  return { data: entry?.value, error: state.error, isLoading: state.isLoading, revalidate, mutate };
}
