import {
  Action,
  ActionPanel,
  closeMainWindow,
  Detail,
  Form,
  Icon,
  Keyboard,
  LaunchProps,
  popToRoot,
  showHUD,
  showToast,
  Toast,
  useNavigation,
} from "@raycast/api";
import { useEffect, useRef, useState } from "react";
import { BlockedSitesList } from "./blocked-sites";
import { cachedStatus, updateCachedStatus } from "./blocker-state";
import {
  BlockerError,
  confirmUnblock,
  errorMessage,
  BlockedEntry,
  requestUnblock,
  stillBlocked,
  UnblockOperation,
  UnblockRequest,
  withoutBlocks,
} from "./lib";

/** Says what changed, and what another block (for example a manual one) still keeps blocked. */
export function unblockedMessage(operations: UnblockOperation[], kept: BlockedEntry[]): string {
  if (operations.some(([command]) => command === "end-pomodoro")) return "🔓 Stalled round ended · site blocks stay";
  const sites = [...new Set(kept.map((entry) => entry.domain.replace(/^www\./, "")))];
  if (sites.length) {
    const tags = [...new Set(kept.flatMap((entry) => entry.tag.split(",")))].join(", ");
    const names = sites.length === 1 ? `${sites[0]} stays` : `${sites.length} sites stay`;
    return `🔓 Unblocked · ${names} blocked by ${tags}`;
  }
  return "🔓 Unblocked · reload the page (browsers can take a minute)";
}

interface UnlockContext {
  operations?: UnblockOperation[];
}

export default function ReviewUnblock(props: LaunchProps<{ launchContext: UnlockContext }>) {
  const operations = props.launchContext?.operations;
  // Opened directly, there is nothing to review yet: pick from the blocked list instead.
  if (!operations?.length) return <BlockedSitesList />;
  return <UnlockForm operations={operations} />;
}

/**
 * The UI displays the wait; the privileged helper independently enforces it. `pushed` forms offer
 * Back on their error page; the command's own form has no screen to go back to.
 */
export function UnlockForm(props: { operations: UnblockOperation[]; pushed?: boolean }) {
  const { pop } = useNavigation();
  const [request, setRequest] = useState<UnblockRequest>();
  const [error, setError] = useState<Error>();
  const [reason, setReason] = useState("");
  const [reasonError, setReasonError] = useState<string>();
  const [busy, setBusy] = useState(false);
  const [attempt, setAttempt] = useState(0);
  const [now, setNow] = useState(Date.now());
  const anchor = useRef({ wall: Date.now(), uptime: performance.now() });
  const submitting = useRef(false);
  const scope = JSON.stringify(props.operations);

  useEffect(() => {
    let active = true;
    setRequest(undefined);
    setError(undefined);
    setReason("");
    void requestUnblock(JSON.parse(scope)).then(
      (value) => {
        if (active) {
          setRequest(value);
          anchor.current = { wall: Date.now(), uptime: performance.now() };
          setNow(Date.now());
        }
      },
      (failure) => {
        if (active) setError(failure instanceof Error ? failure : new Error(String(failure)));
      },
    );
    return () => {
      active = false;
    };
  }, [scope, attempt]);

  useEffect(() => {
    if (!request) return;
    const timer = setInterval(() => setNow(anchor.current.wall + performance.now() - anchor.current.uptime), 1000);
    return () => clearInterval(timer);
  }, [request]);

  if (error) {
    const code = error instanceof BlockerError ? error.code : undefined;
    const locked = code === "FOCUS_LOCKED";
    const title = locked
      ? "Focus is still protected"
      : code === "NOT_STALLED"
        ? "This round is not stalled"
        : request
          ? "Could not confirm this unblock"
          : "Could not prepare this request";
    const advice = locked
      ? "Finish the current round before unblocking. Pausing or closing the timer keeps sites protected."
      : code === "NOT_STALLED"
        ? "A round that is counting again finishes on its own. Your website blocks are unchanged."
        : "Your website blocks are unchanged.";
    return (
      <Detail
        markdown={`## ${title}\n\n${errorMessage(error)}\n\n${advice}`}
        actions={
          <ActionPanel>
            {props.pushed && <Action title="Back" icon={Icon.ArrowLeft} onAction={pop} />}
            <Action
              title="Try Again"
              icon={Icon.ArrowClockwise}
              shortcut={Keyboard.Shortcut.Common.Refresh}
              onAction={() => setAttempt((value) => value + 1)}
            />
          </ActionPanel>
        }
      />
    );
  }

  const wait = Math.max(0, Math.ceil(((request?.readyAt ?? now) - now) / 1000));
  const expired = !!request && now >= request.expiresAt;
  async function confirm() {
    if (!request || submitting.current) return;
    if (wait > 0) {
      await showToast({ style: Toast.Style.Failure, title: `Wait ${wait} more seconds` });
      return;
    }
    if (expired) {
      setAttempt((value) => value + 1);
      return;
    }
    if (!reason.trim() || reason.trim().length > 500) {
      setReasonError("Enter a short reason, up to 500 characters.");
      return;
    }
    submitting.current = true;
    setBusy(true);
    try {
      await confirmUnblock(request.id, reason);
      const before = cachedStatus();
      const kept = before ? stillBlocked(before, props.operations) : [];
      updateCachedStatus((status) => withoutBlocks(status, props.operations));
      await closeMainWindow();
      await showHUD(unblockedMessage(props.operations, kept));
      await popToRoot();
    } catch (failure) {
      setError(failure instanceof Error ? failure : new Error(String(failure)));
    } finally {
      submitting.current = false;
      setBusy(false);
    }
  }

  return (
    <Form
      isLoading={!request || busy}
      navigationTitle="Review Unblock"
      actions={
        <ActionPanel>
          <Action.SubmitForm
            title={expired ? "Start a New Review" : wait ? `Wait ${wait}s` : "Confirm Unblock"}
            icon={Icon.LockUnlocked}
            onSubmit={confirm}
          />
        </ActionPanel>
      }
    >
      <Form.Description title="Request" text={request?.description ?? "Preparing your request…"} />
      <Form.Description
        title="One-minute pause"
        text={
          expired
            ? "This confirmation expired. Start a new review to continue."
            : wait
              ? `Sites stay blocked. You can confirm in ${wait} seconds.`
              : "Ready. Confirm within two minutes, or leave this screen to keep the blocks."
        }
      />
      <Form.TextField
        id="reason"
        title="Why unblock?"
        placeholder="What do you need to do?"
        value={reason}
        onChange={(value) => {
          setReason(value);
          setReasonError(undefined);
        }}
        error={reasonError}
        info="Your reason is checked locally and is not saved."
      />
    </Form>
  );
}
