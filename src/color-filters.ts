import { runAppleScript } from "@raycast/utils";

// macOS has no public API or CLI for Accessibility → Display → Color Filters. These are the
// undocumented functions System Settings itself uses; category 1 is the color filter, and the
// configured filter type and intensity are left untouched.
const script = (body: string) => `
ObjC.import("Foundation");
$.NSBundle.bundleWithPath("/System/Library/PrivateFrameworks/UniversalAccess.framework").load;
$.NSBundle.bundleWithPath("/System/Library/Frameworks/MediaAccessibility.framework").load;
ObjC.bindFunction("_UniversalAccessDStart", ["void", ["int"]]);
ObjC.bindFunction("MADisplayFilterPrefGetCategoryEnabled", ["bool", ["int"]]);
ObjC.bindFunction("MADisplayFilterPrefSetCategoryEnabled", ["void", ["int", "bool"]]);
${body}
String($.MADisplayFilterPrefGetCategoryEnabled(1));
`;

async function run(body: string): Promise<boolean> {
  const result = (await runAppleScript(script(body), { language: "JavaScript" })).trim();
  if (result !== "true" && result !== "false") throw new Error(`Unexpected color filter state: ${result}`);
  return result === "true";
}

/** Whether the system Color Filters switch is on. */
export const colorFiltersEnabled = () => run("");

/** Flips the system Color Filters switch and returns whether filters are now on. */
export const toggleColorFilters = () =>
  run(
    "$._UniversalAccessDStart(8); $.MADisplayFilterPrefSetCategoryEnabled(1, !$.MADisplayFilterPrefGetCategoryEnabled(1));",
  );

export const describeColorFilters = (on: boolean) => (on ? "⚫ Color filters on" : "🌈 Color filters off");
