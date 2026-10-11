# Transfer workflow follow-up — 2026-10-08

Drop Shelf and Clipboard History were rebuilt, signed, installed, and synchronized with their Raycast asset copies.

- **Drop Shelf:** one synchronized shelf panel per display; shared contents, selection, progress, and actions; visibility across apps and Spaces; no focus stealing when shown during a drag. Display changes wait for active drags/dialogs. Finder images and images moved between shelves retain their image pasteboard formats. Active outgoing and pending incoming transfers protect backing files. See [the shelf report](drop-shelf/QA.md).
- **Clipboard History:** quick **⌘⇧V** now pastes the shown clip when the shortcut is released, without Enter. Holding the modifiers still supports cycling. Menu/Raycast browsing remains open for search and deliberate selection. Very fast taps, cold startup, cancellation, and duplicate release events are handled. Reopening history, another delivery/copy, suspension, or Settings cancels an earlier queued paste.

## Verification

- **301 shelf checks**, **122 clipboard checks**, and **8 Raycast launcher checks** passed. Clipboard checks include real focus restoration and a multiline Unicode paste into an owned editor fixture. Additional asynchronous race tests intercept keyboard output and use a private pasteboard.
- Both native release builds passed. Strict signatures and executable hashes match across source assets, installed helpers, and Raycast assets. Clipboard executable SHA-256: `fa8b76371a7ece8e5d3640574cf15e373eb6a28000b0594e7b958bb8db2ad5cd`.
- Each helper has one resident process. Settings URL smoke checks succeeded. Installation preserved shelf history, all 23 existing encrypted clipboard records, preferences, and login settings. The default clipboard shortcut remains **⌘⇧V**.
- Smoke-check cleanup initially targeted a Settings content button by index and armed the shortcut recorder. The temporary override was removed, the original preference-file digest was verified, and both Settings windows were closed using their `AXCloseButton` subrole. Future UI cleanup must use that subrole, not button position.
- Clipboard's 500-entry search fixture peaked at **35.1 ms**; test-process physical footprint was **32 MiB**. Shelf timing and hardware-testing limitations are recorded in its report. These are fixture measurements, not guarantees for every destination app.

Artifacts: `/tmp/drop-shelf-displays-final.log`, `/tmp/clipboard-quick-paste-final.log`, `/tmp/clipboard-history-qa.nNsCVK`, and `/tmp/clipboard-quick-paste-build.log`. The user clipboard was restored after the owned live-paste fixture; shortcut and race tests left it unchanged.

# Earlier UI and UX audit — 2026-10-07

Scope: every tool family in Productivity OS, including the Raycast dashboard and menu bar, Resource Guard, Screenshot Studio, Clipboard History, Drop Shelf, Health Breaks, website blocking/focus, Keep Awake, color filters, and menu bar visibility.

## Improvements

| Surface | Changes |
| --- | --- |
| Dashboard | Search wording and keywords cover tools as well as switches; screenshot shortcut is visible; loading and failed reads no longer imply Off or zero blocked sites. |
| Menu bar | Tools submenu opens screenshots, clipboard, shelves, and health settings; failed visibility/filter reads say Unavailable. |
| Screenshot Studio | Capture, text/video, and editing actions are grouped with distinct icons; settings are reachable from each action; drawing tool selection stays visible; zoom and search have descriptive accessibility labels. |
| Clipboard History | Visible Search and Favorites controls preserve the translucent bezel; empty favorites, failed searches, and paused collection explain the next step; navigation arrows have shortcut hints. |
| Drop Shelf | Empty shelves disable Quick Look, Share, and Copy; truncated labels expose the full value in tooltips. |
| Health Breaks | Settings saves show confirmation; settings render on an opaque background that follows system appearance; reminder popup remains translucent and does not take focus. |
| Keep Awake | Invalid custom duration has inline feedback; repeated submissions are ignored while a session starts. |
| Website blocking | Empty lists offer Focus and Refresh actions; failed dashboard reads show Unavailable. |
| Resource Guard | Search covers jobs and CPU controls; standard Refresh shortcut; repeated mutation requests are ignored while an action is running. |

## Validation

- Extension: 20 Python helper tests and 48 Node tests passed; TypeScript checking and targeted ESLint passed. UI tests exercise actions with simulated macOS integrations and temporary hosts files.
- Health Breaks: 44 native checks passed, including timing, idle/lock/sleep accounting, preview isolation, validation, and keyboard focus.
- Clipboard History: 85 native checks passed, including storage, filtering, Unicode, exclusions, shortcut conflicts, UI behavior, and bounded search/performance. Live paste into another app is now explicitly opt-in (`QA_LIVE_PASTE=1`); this audit skipped it to preserve the working clipboard.
- Drop Shelf: 93 native checks passed, including the new empty-action state, persistence, drag data, capacity, shortcuts, file-operation rollback, and lifecycle stress.
- Screenshot Studio: 66 native checks passed, including selected-tool feedback, layout, rendering, exports, OCR, real capture of an owned window, live scrolling alignment, recording cancellation and finalization, and 40 lifecycle cycles. Measured footprint growth across those cycles was 3 MiB.
- Resource Guard: instruction installation, policy, real app identity/footprint, queue limits, coordinator recovery, process-group isolation, terminal input, cancellation/escalation, and unavailable-metric integration tests passed.
- Reviewed native fixture images of clipboard, shelf, screenshot editor, and health settings/reminder. Fixtures contain synthetic data, not personal clipboard contents.
- All four native release builds and the Raycast production build passed. Installed all four updated apps; verified signatures and byte-for-byte executable matches. Restarted Clipboard History, Drop Shelf, and Health Breaks normally, preserving saved data and startup choices. Screenshot Studio remains available on demand.

Heavy checks ran sequentially through Resource Guard. A 120-second machine sample observed normal/warning memory pressure, 13.9% average CPU busy (46% peak), 5.9 MiB swap-in, and zero swap-out. Allocated swap remained approximately 5,025 MiB. RSS is not physical memory footprint.

## Limits

Native UI fixtures and stateful Raycast tests do not replace manual testing of every workflow inside Raycast. Physical sleep/lock, logout/login, every display scaling configuration, and a complete VoiceOver navigation pass were not exercised. Website blocking and Keep Awake tests use controlled substitutes instead of changing the user's real blocks or sleep session. No claim is made that all possible UI edge cases are covered.
