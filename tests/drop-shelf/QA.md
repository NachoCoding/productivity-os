# Drop Shelf reliability pass — 2026-10-08

Source changes only; nothing was rebuilt into `assets/`, installed, or restarted.

## Changes

- **Delete is selection-only.** Delete and "Remove from Shelf" remove only explicitly selected items. With nothing selected Delete does nothing and the status line says "Select items to remove · ⌘A selects all"; the menu item is disabled. Removing every item of a shelf (2+ items) asks first. Drag-out, copy, Quick Look, share, and export still use the whole stack when nothing is selected.
- **⌘Z undo.** The last removal can be undone with ⌘Z (or "Undo Remove" in the ⋯ menu) for 10 seconds; items return in their original order. Saved images of removed items are kept on disk until that window closes or another removal starts.
- **⌥⇧Space** shows the shelf synchronously from memory and saves it afterwards (later edits are queued behind the save). It no longer activates Drop Shelf: the panel takes keyboard focus while the frontmost app keeps its menu bar. It reuses an open, empty, unnamed, unpinned shelf instead of creating another (also for the menu's New Shelf, `pos-shelf://new`, and `clipboard`). Dialogs and Quick Look still activate the app when opened.
- **`pos-shelf://quit-if-idle`** (launcher protocol) quits with exit 0 only when no shelf is open or visible and no import, copy/ZIP, drag, dialog, or Settings window is active; otherwise it does nothing. It never shows UI.
- **Start at login** writes the shared LaunchAgent (KeepAlive `SuccessfulExit=false`, `ProcessType` Interactive, `ThrottleInterval` 30, Aqua) atomically; turning it off only deletes the file.
- **Damaged `shelves.json`** no longer stops the app: it is moved to `shelves.json.damaged-<epoch>`, the saved images to `Items.damaged-<epoch>`, and the app starts with empty history, an alert, and a "Show Damaged History in Finder" menu item.
- **ZIP/copy** can be cancelled ("Cancel Export" in both menus; Quit offers "Stop and Quit"). ZIP creation stops after 10 minutes. Logout, restart, and shutdown are never blocked; they cancel a running export.
- **Idle and hot-path cost:** the drag monitor does motion math only and reads the drag pasteboard at most once per drag, and is removed while shake is off. Attachment cleanup is debounced to one low-priority sweep without bookmark resolution, and reads the clipboard only after it changed and offers file URLs (never where macOS would show a paste alert; the shelf's own copies are remembered). TIFF is transferred only when no file, promise, URL, or compact image is available. Thumbnails are reapplied only when the visible items change; display copies share one thumbnail cache; bookmarks resolve off the main thread.

## Verification

- `"$HOME/.local/bin/resource-guard" run -- env DROP_SHELF_TEST_SCOPE=headless bash tests/drop-shelf/run.sh` — **271 checks passed** in four of five runs (~38 s each). The other run stopped at the existing check that the real clipboard's change count is unchanged, because the clipboard changed outside the test while the Mac was in use; no tested path writes to it, and the rerun passed. The headless scope runs the store/ZIP/shake checks plus the ingest, import, drag, and new reliability regressions with no on-screen windows, activation, global shortcuts, or reads of the user's clipboard contents. Offscreen shortcut shelf creation p95: **4.5–6.7 ms**.
- The full suite (on-screen windows, focus switching to Finder, real global shortcuts) and `tests/drop-shelf/live` were **compile-checked only** (`swiftc -typecheck` with the run scripts' file lists), because they take focus or move the pointer.
- Release build of `native/drop-shelf/*.swift` succeeded.

Not exercised: on-screen keyboard focus of the non-activating panel and sheets, a real logout, and cancelling a ZIP queued in Resource Guard.

# Drop Shelf across apps and displays — 2026-10-08

Implemented and installed in the standalone helper and Raycast's bundled helper. Each open shelf now has one panel per connected display, sharing its stored contents, selection, expansion, import progress, and actions. Closing any copy closes the logical shelf everywhere, leaving one Recent entry. Position and scroll remain local to each display.

Panels join all desktop Spaces, other apps' Stage Manager sets, and eligible full-screen spaces. Showing a panel during a drag preserves the destination app's focus. Display reconciliation preserves surviving panels, adds/removes copies on hotplug, and waits for active source/destination drags or dialogs. Temporary loss of every display hides the panels without losing their state; closed history is never reopened by a display change.

Images imported from Finder and images passed between shelves now advertise both file URLs and their original image representation. Shelf-to-shelf and menu-bar transfers keep image data lazy. Active outgoing drags and accepted incoming file transfers protect their backing files until delivery completes. A partial copy reports unavailable files while retaining the usable items.

## Verification

- **301 native checks passed**, including actual switching to Finder with the shelf still on-screen, inactive presentation preserving focus, two injected display layouts, primary-panel promotion after disconnect, reconnection, temporary loss of all displays, shared edits/imports/selection, closed-history behavior, and text/link/image/file handoffs.
- **8 shared Raycast launcher checks passed** for the shelf and clipboard helpers.
- Final p95 fixture timings: **0.52 ms warm opening**, **0.32 ms accepted-drop feedback**, **0.23 ms status updates**, and **0.07 ms selection updates**. These measure existing panels and coordinator/render feedback, excluding browser pasteboard extraction, network transfer, and thumbnail generation.
- Release build and strict signature checks passed. All three shelf executable copies match SHA-256 `43b9c90bf015bf23f033ad0978811e02711d75d09fc0b013e78a63a408e05462`.
- Cold and warm Settings launches succeeded with one resident process. Shelf history, preferences, and login configuration remained unchanged during installation.

Artifacts: `/tmp/drop-shelf-displays-final.log`, `/tmp/drop-shelf-qa.0m1HhM`, and the independent real-app-switch probe `/tmp/drop-shelf-focus.vWQVEX/cooperative.log`.

Physical monitor hotplug and full-screen/Stage Manager transitions were not exercised on multiple real displays; their topology and window policies were tested with injected displays and native panel assertions. The browser-to-Finder live automation limitation described below still applies. These checks establish the covered workflows, not complete feature parity with Dropover.

# Earlier import smoothness and reliability work — 2026-10-08

Status: implemented, tested, signed, and installed. The source bundle, installed helper, and Raycast bundled helper have identical executable bytes. Cold and warm Settings URL launches each succeeded on the first attempt with one resident process. Shelf history, preferences, and login configuration remained byte-for-byte unchanged across installation and smoke checks.

## Changes

- Accepted imports are owned by the app, have immediate visible progress, retain input order, reserve capacity, and survive closing/reopening their shelf. Pending shelves cannot be evicted; completed imports restore the normal recent-history bound.
- Every file-promise receiver in one drag uses the same protected destination. Multiple files, partial failures, duplicate/late callbacks, a blocked provider queue, and a 20-second deadline are handled explicitly. Timed-out producers retain staging protection until their callbacks settle, or startup cleanup on the next launch.
- Image bytes are validated instead of trusting MIME types or filename extensions. Original promises take priority, then available pixels, image URLs, and an explicitly labeled link/text fallback. Oversized browser TIFF fallback data does not reject an otherwise usable original promise or URL. Raw images and encoded data URLs share a bounded pending-payload budget.
- Image conversion, quota checks, attachment writes, and history transactions run away from the main actor through serialized store snapshots. At most two import resolvers run concurrently.
- Stable AppKit views preserve scroll position and active drag sources. Multi-selection survives mouse-down/drag, inactive shelves accept the first click, and image data is provided lazily to drag destinations. Thumbnails follow the viewport with two concurrent requests and a bounded cache. Panels remain within usable display bounds.
- Attachment cleanup preserves referenced files and folders while pruning abandoned siblings from completed promise batches.

## Verification

- **245 native checks passed** against the final sources, including actual receiver API fixtures, malformed image responses, delayed imports, lifetime/ordering/reservations, persistence rollback/recovery, shared-folder cleanup, first-click/multi-selection gestures, viewport thumbnail cancellation, placement, and background-worker responsiveness.
- **4 Raycast launcher checks passed.** Raycast's installed asset copy was updated so subsequent commands see the same helper as the installed app.
- A **120-second, 200-item render stress run passed** with zero growth above its warmed-up physical-footprint baseline. Worst render was **42.6 ms**, compared with **101.2 ms** before these changes. The final two cleanup assertions were subsequently verified in the 245-check release run; the UI implementation was unchanged from the stress run.
- Final UI fixture measurements at p95: **0.91 ms warm opening**, **0.39 ms accepted-drop feedback**, **0.28 ms status updates**, and **0.09 ms selection updates**. Opening measures an existing shelf; feedback measures coordinator acceptance and rendering, excluding source-app pasteboard extraction, network transfer, and Quick Look generation.
- Test-process physical footprint peaked at **120 MiB** and ended at **36 MiB** in the stress run. Concurrent system sampling showed **normal memory pressure**, **0 MiB swap-ins/out**, and **15.2% average / 22.8% peak CPU utilization**. These system figures include other applications. RSS and physical footprint are different measurements; RSS totals are not a measure of total physical memory use.
- Strict code-signature verification passed for all three copies. Executable SHA-256: `4693ff70ad0310bc4d4760449500dc2511148e67c0fea2822594f78fcf99946a`.

## Live-automation limits

The isolated live harness served a local image and used owned browser/Finder windows, preserving the general clipboard and production shelves. Chrome loaded the fixture, but synthetic input did not initiate a new source drag: its drag pasteboard did not change and the shelf received no destination callback. The inactive shelf did initiate a native outgoing file drag, but pointer coordinates diverged from the requested endpoint and Finder delivery was not verified. Safari had neither existing AppleScript permission nor usable Accessibility geometry. No permissions were changed.

**Real browser-to-shelf and shelf-to-Finder end-to-end success remains unverified.** These automation limits are not evidence that real browser drops passed or that the import resolver failed. Native promise, pasteboard, and interaction regressions passed. All task-owned live windows, helper processes, and HTTP servers were cleaned up; the previous app and pointer position were restored. Multiple physical displays, login/logout, and sending through external Share destinations were not exercised.

## Reproduction and evidence

```sh
"$HOME/.local/bin/resource-guard" run -- bash tests/drop-shelf/run.sh
"$HOME/.local/bin/resource-guard" run -- env DROP_SHELF_SOAK_SECONDS=120 bash tests/drop-shelf/run.sh
"$HOME/.local/bin/agent-load-check" --seconds 120 --output /tmp/drop-shelf-new-load.json
"$HOME/.local/bin/resource-guard" run -- bash tests/drop-shelf/live/run.sh
```

Run the resource sampler during the workload. Live automation moves the pointer and requires the foreground UI to remain available; it uses existing permissions only and exits unsuccessfully for incomplete scenarios.

Evidence:

- `/tmp/drop-shelf-smooth-release-tests.log` — final 245 native checks and timing measurements.
- `/tmp/drop-shelf-smooth-final.log` — stress run and signed release build.
- `/tmp/drop-shelf-smooth-load.json` — two-minute system resource sample.
- `/tmp/drop-shelf-qa.KBjGrY/` — final isolated stores and rendered fixtures.
- `/tmp/drop-shelf-live.ScFUxz/live-results.log` — live input diagnostics and coverage limits.
- `/tmp/drop-shelf-smooth-install-before.json` — pre-install preservation hashes.

---

# Drop Shelf heavy QA — 2026-10-07

Status: passed; corrected native helper and Raycast extension built and installed. Installed executable matches the bundled build and passes strict code-signature verification.

## Findings fixed

- A shelf-owned image dragged to another shelf became an ordinary file reference. Cleanup previously ignored that reference and could delete its backing file. Cleanup now retains every shelf reference, current clipboard file references, and files used by an active export.
- Moving a selection to a new shelf performed three separate writes. A failed write could leave duplicate references. Splitting and closing/evicting shelves now use atomic state transactions.
- Repeated Quick Look previews accumulated temporary text files. Previews now reuse bounded per-item files, prune unused cache entries, and release their cache and panel delegate on close.
- An unavailable shortcut replaced the working shortcut. Registration now restores the previous binding and preferences on conflict. Closing Settings cancels shortcut recording.
- Invalid stored colors and duplicate/oversized entries could reach rendering. State validation rejects them without replacing the stored history.

## Verification

- 92 native checks: file bookmarks/renames, exact Unicode and whitespace, cross-shelf image retention, image cleanup/leases, failed-write rollback, atomic split persistence, 200-item and 30-shelf bounds, pinned retention, quotas, malformed state, shake detection, pasteboard import/export, preview cache bounds, selection, window focus, Escape, and real Carbon shortcut conflicts.
- Real ZIP compression/extraction verifies nested folders, unusual names, byte preservation, collision handling, and failure behavior. Test compression runs inside the suite's existing Resource Guard slot; production compression still uses Resource Guard directly.
- 64 extension checks (20 Python, 44 Node), TypeScript checking, and Raycast production build pass.
- Installed UI: Create ZIP opens the folder chooser, creates the archive in the selected test folder, and passes archive CRC and original-byte comparison. Global shelf and clipboard shortcuts both open their panels.
- Test shelves and Finder windows were cleaned up. Other shelves, original files, and the user's clipboard were preserved. No messages, uploads, or external sharing were sent.

## Resource observations

A 120-cycle stress test alternated compact/expanded rendering of a 200-item shelf. Worst render: 85.5 ms. The test process peaked at 125 MiB physical footprint and ended at 34 MiB, with no growth over its warmed-up baseline. This process includes test fixtures and is not the installed helper's idle footprint.

A concurrent 120-second `agent-load-check` sample observed normal system memory pressure, 6.14% average / 16.7% peak system CPU utilization, 0.34 MiB swap-ins, and zero swap-outs. These system measurements include other applications.

After installation and cleanup, a five-second idle sample measured the helper at 11.09 MiB physical footprint, 58.33 MiB RSS, and 0.000% of one CPU core over that interval. RSS and physical footprint are different measurements and must not be added together.

## Reproduce

```sh
"$HOME/.local/bin/resource-guard" run -- env DROP_SHELF_SOAK_SECONDS=120 bash tests/drop-shelf/run.sh
"$HOME/.local/bin/agent-load-check" --seconds 120 --output /tmp/drop-shelf-new-sample.json
"$HOME/.local/bin/resource-guard" run -- npm test
```

Run the sampler during the workload, using a new output filename. Native tests use isolated stores and preferences and do not replace the general clipboard.

Evidence from this run:

- `/tmp/drop-shelf-heavy-repro.log` — original cross-shelf retention failure.
- `/tmp/drop-shelf-heavy-final2.log` — stress and extension checks.
- `/tmp/drop-shelf-heavy-release.log` — final native regressions and rebuild.
- `/tmp/drop-shelf-heavy-resource-sample.json` — two-minute system resource sample.
- `/tmp/drop-shelf-heavy-idle.json` — installed helper idle measurement.
- `/tmp/drop-shelf-qa.HU8QMG/` — final isolated native fixtures and UI snapshots.

Coverage limits: no external Share destination was sent data; cloud integrations and file-promise-only drags remain outside the feature's implemented scope. This run did not exercise multiple physical displays or a full logout/login cycle.
