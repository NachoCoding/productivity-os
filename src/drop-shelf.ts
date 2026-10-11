import { shelfAction } from "./drop-shelf-client";
export default async function Command() {
  await shelfAction("new");
}
