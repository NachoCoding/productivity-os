import { Action, ActionPanel, Detail, Icon, useNavigation } from "@raycast/api";
import { useEffect, useRef, useState } from "react";
import BlockDiagnostics from "./block-diagnostics";
import { BlockPresetList } from "./block-preset";
import { cachedSetup, forgetSetup, updateCachedStatus, verifySetup } from "./blocker-state";
import { blockDomains, domainRegex, errorMessage, hostVariants, needsSetup, normalizeDomain, withBlocks } from "./lib";
import SetupInstructions from "./show-setup";

export default function BlockSite(props: { arguments: { domain: string } }) {
  const { push } = useNavigation();
  // A cached "set up" verdict lets the block start at once; the helper call itself reports a missing setup.
  const [setup, setSetup] = useState<boolean | undefined>(() => (cachedSetup()?.ok ? true : undefined));
  const attempted = useRef("");
  const [saved, setSaved] = useState(false);
  const [error, setError] = useState("");
  const [attempt, setAttempt] = useState(0);
  const domain = normalizeDomain(props.arguments.domain ?? "");
  const valid = domainRegex.test(domain);
  // Block the bare domain and its www variant together; hosts entries match exact names only.
  const domains = valid ? hostVariants(domain) : [];

  useEffect(() => {
    if (setup !== undefined) return;
    void verifySetup().then((result) => setSetup(result.ok));
  }, [setup]);

  useEffect(() => {
    const key = `${domain}#${attempt}`;
    if (!setup || !valid || attempted.current === key) return;
    attempted.current = key;
    setError("");
    void (async () => {
      try {
        await blockDomains(domains, "manual");
        updateCachedStatus((status) => withBlocks(status, domains, "manual"));
        setSaved(true);
      } catch (err) {
        if (needsSetup(err)) {
          forgetSetup();
          setSetup(false);
        } else {
          setError(errorMessage(err));
        }
      }
    })();
  }, [setup, valid, domain, attempt]);

  const recheck = async () => {
    const result = await verifySetup();
    if (result.ok) setSetup(true);
    return result.ok;
  };

  if (setup === undefined) return <Detail isLoading />;
  if (!setup) return <SetupInstructions onCheckAgain={recheck} />;
  if (saved) return <BlockDiagnostics domains={domains} saved />;

  const shown = (props.arguments.domain ?? "").replace(/[`\r\n]/g, "").trim();
  const markdown = !valid
    ? `## Invalid domain\n\n\`${shown}\` is not a hostname this tool can block.\n\nEnter a domain such as \`example.com\` or an HTTP/HTTPS URL. IP addresses and single-label names such as \`localhost\` are not supported.`
    : error
      ? `## Could not block site\n\n${error}`
      : `Blocking **${domains.join("** and **")}**…`;

  return (
    <Detail
      isLoading={valid && !error}
      markdown={markdown}
      actions={
        <ActionPanel>
          {error && <Action title="Retry" icon={Icon.ArrowClockwise} onAction={() => setAttempt((n) => n + 1)} />}
          <Action
            title="Block Preset…"
            icon={Icon.Layers}
            onAction={() => push(<BlockPresetList />)}
            shortcut={{ modifiers: ["cmd", "shift"], key: "p" }}
          />
        </ActionPanel>
      }
    />
  );
}
