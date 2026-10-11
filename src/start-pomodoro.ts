import { setupDone } from "./blocker-state";
import { healthAction } from "./health-breaks-client";
import { openCommand } from "./launch";

/** Rounds need the website blocker; the setup verdict is cached, so a set-up Mac starts at once. */
export default async function StartPomodoro() {
  if (!(await setupDone())) {
    await openCommand("run-setup");
    return;
  }
  await healthAction("pomodoro-start");
}
