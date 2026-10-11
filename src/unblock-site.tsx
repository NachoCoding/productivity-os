import { Action, ActionPanel, Detail, Icon, LaunchProps } from "@raycast/api";
import { useRef } from "react";
import { BlockedSitesList } from "./blocked-sites";
import { useBlocker } from "./blocker-state";
import { errorMessage, focusLock, hostVariants, normalizeDomain, UnblockOperation } from "./lib";
import SetupInstructions from "./show-setup";
import { UnlockForm } from "./unlock-request";

export default function UnblockSite(props: LaunchProps<{ arguments: Arguments.UnblockSite }>) {
  const raw = props.arguments.domain?.trim() ?? "";
  if (!raw) return <BlockedSitesList />;
  return <UnblockDirect raw={raw} domain={normalizeDomain(raw)} />;
}

// Reviews the typed domain and its www variant in one request when either is blocked; otherwise
// falls back to the filtered list so a partial or mistyped name still gets the user to the right entry.
// The choice waits for a fresh read (the cached status opens nothing) and is then kept.
function UnblockDirect(props: { raw: string; domain: string }) {
  const blocker = useBlocker();
  const choice = useRef<UnblockOperation[] | "list" | undefined>(undefined);

  if (blocker.setup === false) return <SetupInstructions onCheckAgain={blocker.recheck} />;
  const status = blocker.status;
  if (!choice.current && !blocker.isLoading && status && !blocker.error) {
    const targets = props.domain
      ? hostVariants(props.domain).filter((name) => status.entries.some((entry) => entry.domain === name))
      : [];
    // During focus the list explains the lock instead of opening a review the helper refuses.
    choice.current =
      targets.length && !focusLock(status) ? targets.map((target): UnblockOperation => ["remove", target]) : "list";
  }
  if (choice.current === "list") return <BlockedSitesList initialSearch={props.raw} preloaded />;
  if (choice.current) return <UnlockForm operations={choice.current} />;
  if (blocker.error && !blocker.isLoading) {
    return (
      <Detail
        markdown={`## Could not unblock ${props.domain || props.raw}\n\n${errorMessage(blocker.error)}`}
        actions={
          <ActionPanel>
            <Action title="Retry" icon={Icon.ArrowClockwise} onAction={() => blocker.revalidate()} />
          </ActionPanel>
        }
      />
    );
  }
  return <Detail isLoading markdown={`Preparing review for **${props.domain || props.raw}**…`} />;
}
