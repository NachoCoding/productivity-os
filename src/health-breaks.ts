import { healthAction } from "./health-breaks-client";
export default async function Command() {
  await healthAction("settings");
}
