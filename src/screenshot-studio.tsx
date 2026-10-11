import { Action, ActionPanel, Icon, List } from "@raycast/api";
import { ScreenshotCommand, screenshotAction } from "./screenshot-studio-client";

const commands: { title: string; command: ScreenshotCommand; detail: string }[] = [
  { title: "Capture", command: "capture", detail: "Choose an area, window, display, text, or recording" },
  { title: "Capture Area", command: "area", detail: "Drag a region; Space switches to windows" },
  { title: "Capture Window", command: "window", detail: "Select a window" },
  { title: "Capture Display", command: "display", detail: "Capture the display under your pointer" },
  { title: "Capture Previous Area", command: "repeat", detail: "Repeat the last selection" },
  { title: "Delayed Capture", command: "delay", detail: "Capture after the configured delay" },
  { title: "Scrolling Capture", command: "scroll", detail: "Vertical or horizontal; automatic or manual" },
  { title: "Copy Text from Screen", command: "text", detail: "Recognize text locally and copy it" },
  { title: "Record Short Clip", command: "record", detail: "Up to two minutes; optional audio, trim, and GIF" },
  { title: "Open Image or Project", command: "open", detail: "Annotate an existing file" },
  { title: "Edit Clipboard Image", command: "clipboard", detail: "Open the clipboard in the editor" },
  { title: "Unlock Pinned References", command: "unlock-pins", detail: "Restore interaction with click-through pins" },
  {
    title: "Screenshot Settings",
    command: "settings",
    detail: "Pointer, shadows, dimensions, aspect ratio, and delay",
  },
];

const groups = [
  { title: "Capture", commands: ["capture", "area", "window", "display", "repeat", "delay"] },
  { title: "Text, Scrolling & Video", commands: ["scroll", "text", "record"] },
  { title: "Edit & Organize", commands: ["open", "clipboard", "unlock-pins", "settings"] },
];
const icons: Partial<Record<ScreenshotCommand, Icon>> = {
  text: Icon.Text,
  record: Icon.Video,
  scroll: Icon.ArrowDown,
  open: Icon.Folder,
  clipboard: Icon.Clipboard,
  settings: Icon.Gear,
  "unlock-pins": Icon.Pin,
  delay: Icon.Clock,
  repeat: Icon.ArrowClockwise,
  window: Icon.AppWindow,
  display: Icon.Desktop,
};

export default function ScreenshotStudio() {
  return (
    <List searchBarPlaceholder="Search capture, text, video, or editing tools…">
      <List.EmptyView
        title="No matching capture tools"
        description="Try area, window, text, record, clipboard, or settings."
      />
      {groups.map((group) => (
        <List.Section key={group.title} title={group.title}>
          {commands
            .filter(({ command }) => group.commands.includes(command))
            .map(({ title, command, detail }) => (
              <List.Item
                key={command}
                id={command}
                title={title}
                subtitle={detail}
                keywords={[command, detail]}
                icon={icons[command] ?? Icon.Camera}
                actions={
                  <ActionPanel>
                    <Action title={title} onAction={() => screenshotAction(command)} />
                    {command !== "settings" && (
                      <Action
                        title="Screenshot Settings"
                        icon={Icon.Gear}
                        onAction={() => screenshotAction("settings")}
                      />
                    )}
                  </ActionPanel>
                }
              />
            ))}
        </List.Section>
      ))}
    </List>
  );
}
