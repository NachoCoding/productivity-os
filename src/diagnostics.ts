import { lookup } from "dns/promises";

const LOOKUP_TIMEOUT_MS = 5000;

export function addressesAreBlocked(addresses: string[]): boolean {
  return (
    addresses.length > 0 &&
    addresses.every(
      (address) =>
        address === "::1" || address === "0.0.0.0" || address === "::" || /^127\.\d+\.\d+\.\d+$/.test(address),
    )
  );
}

export async function diagnoseDomain(domain: string) {
  // A stalled resolver must not leave the check spinning forever.
  let timer: ReturnType<typeof setTimeout> | undefined;
  const timeout = new Promise<never>((_, reject) => {
    timer = setTimeout(() => reject(new Error(`Looking up ${domain} timed out`)), LOOKUP_TIMEOUT_MS);
  });
  try {
    const records = await Promise.race([lookup(domain, { all: true }), timeout]);
    const addresses = [...new Set(records.map((record) => record.address))];
    return { addresses, blocked: addressesAreBlocked(addresses) };
  } finally {
    clearTimeout(timer);
  }
}
