import { healthAction } from "./health-breaks-client";

export default async function PostureCoach() {
  await healthAction("posture");
}
