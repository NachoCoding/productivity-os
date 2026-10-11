/// <reference types="@raycast/api">

/* 🚧 🚧 🚧
 * This file is auto-generated from the extension's manifest.
 * Do not modify manually. Instead, update the `package.json` file.
 * 🚧 🚧 🚧 */

/* eslint-disable @typescript-eslint/ban-types */

type ExtensionPreferences = {}

/** Preferences accessible in all the extension's commands */
declare type Preferences = ExtensionPreferences

declare namespace Preferences {
  /** Preferences accessible in the `dashboard` command */
  export type Dashboard = ExtensionPreferences & {}
  /** Preferences accessible in the `start-pomodoro` command */
  export type StartPomodoro = ExtensionPreferences & {}
  /** Preferences accessible in the `pomodoro` command */
  export type Pomodoro = ExtensionPreferences & {}
  /** Preferences accessible in the `posture-coach` command */
  export type PostureCoach = ExtensionPreferences & {}
  /** Preferences accessible in the `unlock-request` command */
  export type UnlockRequest = ExtensionPreferences & {}
  /** Preferences accessible in the `health-breaks` command */
  export type HealthBreaks = ExtensionPreferences & {}
  /** Preferences accessible in the `health-break-now` command */
  export type HealthBreakNow = ExtensionPreferences & {}
  /** Preferences accessible in the `drop-shelf` command */
  export type DropShelf = ExtensionPreferences & {}
  /** Preferences accessible in the `drop-shelf-clipboard` command */
  export type DropShelfClipboard = ExtensionPreferences & {}
  /** Preferences accessible in the `drop-shelf-settings` command */
  export type DropShelfSettings = ExtensionPreferences & {}
  /** Preferences accessible in the `clipboard-history` command */
  export type ClipboardHistory = ExtensionPreferences & {}
  /** Preferences accessible in the `clipboard-history-settings` command */
  export type ClipboardHistorySettings = ExtensionPreferences & {}
  /** Preferences accessible in the `resource-guard` command */
  export type ResourceGuard = ExtensionPreferences & {}
  /** Preferences accessible in the `capture-recording` command */
  export type CaptureRecording = ExtensionPreferences & {}
  /** Preferences accessible in the `capture-text` command */
  export type CaptureText = ExtensionPreferences & {}
  /** Preferences accessible in the `capture-scroll` command */
  export type CaptureScroll = ExtensionPreferences & {}
  /** Preferences accessible in the `capture-window` command */
  export type CaptureWindow = ExtensionPreferences & {}
  /** Preferences accessible in the `capture-area` command */
  export type CaptureArea = ExtensionPreferences & {}
  /** Preferences accessible in the `capture-screenshot` command */
  export type CaptureScreenshot = ExtensionPreferences & {}
  /** Preferences accessible in the `screenshot-studio` command */
  export type ScreenshotStudio = ExtensionPreferences & {}
  /** Preferences accessible in the `block-site` command */
  export type BlockSite = ExtensionPreferences & {}
  /** Preferences accessible in the `unblock-site` command */
  export type UnblockSite = ExtensionPreferences & {}
  /** Preferences accessible in the `blocked-sites` command */
  export type BlockedSites = ExtensionPreferences & {}
  /** Preferences accessible in the `block-preset` command */
  export type BlockPreset = ExtensionPreferences & {}
  /** Preferences accessible in the `start-focus-session` command */
  export type StartFocusSession = ExtensionPreferences & {}
  /** Preferences accessible in the `quick-focus` command */
  export type QuickFocus = ExtensionPreferences & {}
  /** Preferences accessible in the `focus-status` command */
  export type FocusStatus = ExtensionPreferences & {}
  /** Preferences accessible in the `toggle-color-filters` command */
  export type ToggleColorFilters = ExtensionPreferences & {}
  /** Preferences accessible in the `toggle-menu-bar-icons` command */
  export type ToggleMenuBarIcons = ExtensionPreferences & {}
  /** Preferences accessible in the `lock-keep-awake` command */
  export type LockKeepAwake = ExtensionPreferences & {}
  /** Preferences accessible in the `amphetamine-start` command */
  export type AmphetamineStart = ExtensionPreferences & {}
  /** Preferences accessible in the `amphetamine-quick-start` command */
  export type AmphetamineQuickStart = ExtensionPreferences & {
  /** Display Sleep - When enabled, the session keeps the Mac awake but lets the display turn off. */
  "displaySleepAllowed": boolean
}
  /** Preferences accessible in the `amphetamine-end` command */
  export type AmphetamineEnd = ExtensionPreferences & {}
  /** Preferences accessible in the `amphetamine-remaining` command */
  export type AmphetamineRemaining = ExtensionPreferences & {}
  /** Preferences accessible in the `amphetamine-configure` command */
  export type AmphetamineConfigure = ExtensionPreferences & {}
  /** Preferences accessible in the `run-setup` command */
  export type RunSetup = ExtensionPreferences & {}
}

declare namespace Arguments {
  /** Arguments passed to the `dashboard` command */
  export type Dashboard = {}
  /** Arguments passed to the `start-pomodoro` command */
  export type StartPomodoro = {}
  /** Arguments passed to the `pomodoro` command */
  export type Pomodoro = {}
  /** Arguments passed to the `posture-coach` command */
  export type PostureCoach = {}
  /** Arguments passed to the `unlock-request` command */
  export type UnlockRequest = {}
  /** Arguments passed to the `health-breaks` command */
  export type HealthBreaks = {}
  /** Arguments passed to the `health-break-now` command */
  export type HealthBreakNow = {}
  /** Arguments passed to the `drop-shelf` command */
  export type DropShelf = {}
  /** Arguments passed to the `drop-shelf-clipboard` command */
  export type DropShelfClipboard = {}
  /** Arguments passed to the `drop-shelf-settings` command */
  export type DropShelfSettings = {}
  /** Arguments passed to the `clipboard-history` command */
  export type ClipboardHistory = {}
  /** Arguments passed to the `clipboard-history-settings` command */
  export type ClipboardHistorySettings = {}
  /** Arguments passed to the `resource-guard` command */
  export type ResourceGuard = {}
  /** Arguments passed to the `capture-recording` command */
  export type CaptureRecording = {}
  /** Arguments passed to the `capture-text` command */
  export type CaptureText = {}
  /** Arguments passed to the `capture-scroll` command */
  export type CaptureScroll = {}
  /** Arguments passed to the `capture-window` command */
  export type CaptureWindow = {}
  /** Arguments passed to the `capture-area` command */
  export type CaptureArea = {}
  /** Arguments passed to the `capture-screenshot` command */
  export type CaptureScreenshot = {}
  /** Arguments passed to the `screenshot-studio` command */
  export type ScreenshotStudio = {}
  /** Arguments passed to the `block-site` command */
  export type BlockSite = {
  /** Domain (e.g. instagram.com) */
  "domain": string
}
  /** Arguments passed to the `unblock-site` command */
  export type UnblockSite = {
  /** Domain (optional) */
  "domain": string
}
  /** Arguments passed to the `blocked-sites` command */
  export type BlockedSites = {}
  /** Arguments passed to the `block-preset` command */
  export type BlockPreset = {}
  /** Arguments passed to the `start-focus-session` command */
  export type StartFocusSession = {}
  /** Arguments passed to the `quick-focus` command */
  export type QuickFocus = {
  /** Block (Social) */
  "preset": "social" | "news" | "video" | "custom",
  /** Minutes (30) */
  "minutes": string
}
  /** Arguments passed to the `focus-status` command */
  export type FocusStatus = {}
  /** Arguments passed to the `toggle-color-filters` command */
  export type ToggleColorFilters = {}
  /** Arguments passed to the `toggle-menu-bar-icons` command */
  export type ToggleMenuBarIcons = {}
  /** Arguments passed to the `lock-keep-awake` command */
  export type LockKeepAwake = {
  /** Minutes (no limit) */
  "minutes": string
}
  /** Arguments passed to the `amphetamine-start` command */
  export type AmphetamineStart = {}
  /** Arguments passed to the `amphetamine-quick-start` command */
  export type AmphetamineQuickStart = {
  /** Hours (empty = no limit) */
  "hours": string,
  /** Minutes */
  "minutes": string,
  /** Seconds */
  "seconds": string
}
  /** Arguments passed to the `amphetamine-end` command */
  export type AmphetamineEnd = {}
  /** Arguments passed to the `amphetamine-remaining` command */
  export type AmphetamineRemaining = {}
  /** Arguments passed to the `amphetamine-configure` command */
  export type AmphetamineConfigure = {}
  /** Arguments passed to the `run-setup` command */
  export type RunSetup = {}
}
