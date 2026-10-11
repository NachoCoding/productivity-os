import { Action, ActionPanel, Detail, Icon, Keyboard, useNavigation } from "@raycast/api";
import { usePromise } from "@raycast/utils";
import { useBlocker } from "./blocker-state";
import { diagnoseDomain } from "./diagnostics";
import { describeLock, errorMessage, focusLock, UnblockOperation } from "./lib";
import { UnlockForm } from "./unlock-request";

const diagnoseAll = (domains: string[]) => Promise.all(domains.map(diagnoseDomain));

/** Shows resolution results for one or more hostnames; `domains[0]` names the page. */
export default function BlockDiagnostics(props: { domains: string[]; saved?: boolean }) {
  const { push } = useNavigation();
  const query = usePromise(diagnoseAll, [props.domains], { onError: () => undefined });
  // The opener has already read the status (or will on its next open); the cached copy is enough to
  // tell whether an unblock review would be refused.
  const lock = focusLock(useBlocker({ execute: false }).status);
  const results = query.data;
  const heading = props.saved ? "Block entry saved" : "Check website block";
  const plural = props.domains.length > 1;
  const status = query.isLoading
    ? "Checking macOS name resolution…"
    : query.error
      ? `Could not check resolution: ${errorMessage(query.error)}`
      : results?.every((result) => result.blocked)
        ? `**macOS resolves ${plural ? "these hostnames" : "this hostname"} to a blocked address.**`
        : `**macOS blocking is not verified for ${plural ? "every hostname" : "this hostname"}.**`;
  const addresses = results
    ? props.domains
        .map((domain, index) => {
          const list = results[index].addresses;
          return `- \`${domain}\`: ${list.length ? list.map((address) => `\`${address}\``).join(", ") : "none"}`;
        })
        .join("\n")
    : "";
  const markdown = `## ${heading}: ${props.domains.join(", ")}

${status}

${addresses}

### If the website still loads

A saved hosts entry does not stop connections your browser already opened. Fully quit your browser with **⌘Q**, reopen it, and try the exact address again. A tab reload alone may reuse an existing connection.

Check the final hostname in the address bar: hosts entries match exact names, so \`youtube.com\` and \`www.youtube.com\` are separate. Block Site and presets add both; other subdomains need their own block.

If it still loads after quitting, a proxy, VPN, or Safari Private Relay may be resolving the website elsewhere. Hosts blocking cannot guarantee browser enforcement through those routes.

This check verifies macOS resolution only; it does not inspect your browser's connections.
${lock ? `\n_${describeLock(lock)}: blocks can be removed after the current focus ends._\n` : ""}`;
  return (
    <Detail
      isLoading={query.isLoading}
      markdown={markdown}
      actions={
        <ActionPanel>
          <Action title="Check Again" icon={Icon.ArrowClockwise} onAction={() => query.revalidate()} />
          <Action.CopyToClipboard title="Copy Diagnostic Report" content={markdown} />
          {!lock && (
            <Action
              title={props.saved ? "Undo: Unblock Site" : plural ? "Unblock These Sites" : "Unblock Site"}
              icon={Icon.LockUnlocked}
              style={Action.Style.Destructive}
              shortcut={Keyboard.Shortcut.Common.Remove}
              onAction={() => {
                const operations = props.domains.map((domain): UnblockOperation =>
                  props.saved ? ["remove-tag", domain, "manual"] : ["remove", domain],
                );
                push(<UnlockForm operations={operations} pushed />);
              }}
            />
          )}
        </ActionPanel>
      }
    />
  );
}
