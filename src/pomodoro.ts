import { healthAction } from "./health-breaks-client";

/** Opens the Pomodoro window; Health Breaks reports any blocker problem there, so no setup check runs first. */
export default async function Pomodoro() {
  await healthAction("pomodoro");
}
