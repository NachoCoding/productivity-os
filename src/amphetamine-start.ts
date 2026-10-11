import { startDefaultKeepAwake } from "./amphetamine";

/** Amphetamine's default session length; a running session is left alone. */
export default async function StartNewSession() {
  await startDefaultKeepAwake();
}
