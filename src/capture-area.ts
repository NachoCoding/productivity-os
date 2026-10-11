import { screenshotAction } from "./screenshot-studio-client";

export default async function Command() {
  await screenshotAction("area");
}
