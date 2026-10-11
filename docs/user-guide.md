# User guide

[Documentation index](README.md) · [Installation](installation.md) · [Troubleshooting](troubleshooting.md)

A macOS-only Raycast extension (manifest `platforms: ["macOS"]`) for resource protection and focus: Resource Guard helps free RAM for Warp and agents and coordinates heavy coding jobs across sessions; it blocks exact website hostnames through `/etc/hosts`, with presets and timed focus sessions, toggles the system Color Filters (for example Grayscale) in one step, hides menu bar icons, and controls Amphetamine keep-awake sessions.

## Install or update

Follow the [source installation guide](installation.md). Run all commands from the repository root.

### Upgrading from Site Blocker

This project was previously named Site Blocker. Rerun setup once after updating: the installer moves the helper, sudoers rule, and LaunchDaemon to the `productivity-os` names and removes the `site-blocker` ones, and the helper rewrites the `# >>> site-blocker >>>` section of `/etc/hosts` under `# >>> productivity-os >>>` markers, keeping every block and any running focus session. Until setup is rerun, existing blocks stay in force and the commands show the setup screen. If both marker pairs are ever present, the helper refuses to write; merge them by hand.

The original installation stored a sudo-enabled script in a user-writable directory. Rerun setup to replace that sudoers rule. Existing manual and preset entries are preserved. Old focus entries have no expiry metadata: use **Menu Bar Focus Timer → Review Leftover Focus Blocks…** to remove them. The old `~/.config/site-blocker` folder is no longer used.

## Commands

### Pomodoro and deliberate unblocking

Run **Start Pomodoro** for a one-click focus round. It never opens a window or takes keyboard focus: a three-second confirmation (for example “Focus started · 25:00 · Blocking Social + News”) appears and the countdown stays in the menu bar. When a round is ready it starts the next focus; when one is already running it only shows the status; errors open the Pomodoro controls. **Pomodoro** opens the controls, and the dashboard's **Pomodoro Settings** opens durations and sites. Defaults are **25 minutes focus**, **5 minutes break**, and a **15-minute break after four rounds**. Social and News are selected initially; settings can change future durations and the site selection for a new plan. The existing Health Breaks helper owns the native menu-bar countdown and small control window; no additional resident application is needed. The countdown ticks on whole seconds and runs smoothly between the helper's ten-second checkpoints.

Focus time pauses when the Mac is locked, asleep, or the user session becomes inactive. Returning resumes it unless you manually paused. If the helper reports a round paused while you are actually at the Mac (for example when unlocking races its session check, or a notification was missed), Health Breaks retries after 2 seconds, then every 10 and 30 seconds, and it keeps itself out of App Nap while focus runs. Reading without keyboard input does not pause the timer. Breaks count elapsed wall time while away; a completed break waits for **Start Next Round**. No next focus lock starts automatically. Website blocks stay in place through breaks and after stopping the timer. Deliberately unblocking a site during a break preserves your round progress; starting the next focus blocks the selected sites again.

An unfinished round cannot be unblocked, shortened, replaced, or cleared by another command. This also applies while paused and after quitting or restarting the app. Reopen Pomodoro to resume unfinished progress. Raycast shows the actions the helper would refuse as “Locked until hh:mm” (or “Locked during focus” while paused) instead of offering them. The one exception is a **stalled** round: if focus has made no progress for 30 minutes while you were present (unlocked, input within the last five minutes, and not manually paused)—for example because Health Breaks cannot run—**End Stalled Round…** appears in the dashboard, Blocked Sites and the menu bar. It goes through the same one-minute review; confirming ends the plan and keeps every site block, which you can then remove through ordinary reviews. Only the root expiry daemon measures stalled time. The privileged helper owns the remaining time; the app cannot submit a completion time. Ten-second checkpoints use an uptime clock that excludes sleep; missing or uncertain monitoring preserves protection and conservatively pauses progress. Recovery can restore up to ten seconds of remaining time.

Outside an unfinished focus session, any removal—including preset toggles, Undo, and Unblock All—opens the same **one-minute review**. Enter a short reason and confirm within two minutes after the wait. Leaving the review keeps sites blocked. Bare and `www` hostnames share one review. The helper enforces the cooldown independently of the UI and checks protection again on confirmation. Reasons are checked locally and never saved. Adding blocks is immediate.

### Optional posture coach

Run **Posture Coach** in Raycast, or open it from Health Breaks, for local posture reminders whenever you are actively using your Mac. It works independently of Pomodoro and stays **off until explicitly enabled and calibrated**. Only the MacBook's built-in camera is eligible; an iPhone or another camera is never selected as a fallback. Choose **Enable & Calibrate** while your Mac is awake and unlocked. The preview starts on during calibration so you can keep your face and both shoulders visible; you can hide it with the checkbox. Setup collects steady observations over at least five seconds and ends within about 30 seconds with a saved baseline or a visible explanation. Brief tracking gaps do not discard all progress. Monitoring begins only after a baseline is saved, and the preview closes when calibration ends.

Use **Recalibrate** after moving your screen or seat. Cancelling or failing a new calibration preserves the previous baseline, so eligible monitoring can resume. The latest calibration result stays visible even when the live status changes. **Test Reminder** shows the reminder without requesting camera access, enabling coaching, or changing a saved calibration; it checks the popup, not camera detection.

Native AVFoundation and Vision process low-resolution frames, normally once every three seconds. Calibration runs the camera at 5 fps; once a baseline is saved it drops to the slowest rate the camera supports (at least 1 fps). There is one inference in flight, no permanent preview, no frame queue, no recording, and no upload. Only calibration numbers and settings are saved. Ten seconds of sustained change from your calibrated head/shoulder position can produce a quiet reminder on the next tracking sample; uncertain views suppress reminders. Pomodoro starts, pauses, and breaks do not change posture monitoring. Health Breaks' **Pause for One Hour** pauses automatic posture monitoring too, while still allowing explicit calibration. Idle, lock, sleep, camera contention, or closing unfinished calibration stops or pauses camera use. Existing health reminders and the Pomodoro keep working if camera permission is denied or the camera is unavailable.

The resource target is at most 150 MiB of additional physical footprint and 5% average CPU of one core. Monitoring slows down or pauses when its budget is exceeded. These are performance targets, not a claim that camera processing is free. Real posture-detection accuracy must be checked with your camera framing; the feature is a movement/posture reminder, not a measurement of spinal alignment.

### Health Breaks

Open **Health Breaks** in Raycast or the Productivity OS dashboard to adjust reminders. Defaults: eyes every **20 active minutes**, stretching every **45**, and water every **60**. A small translucent popup appears without taking keyboard focus. **Done** resets the displayed reminders; **Snooze** postpones them for five active minutes. An unanswered popup automatically snoozes after 45 seconds. Reminders due together share one popup. **Take a Health Break** shows all three immediately; **Preview Popup** demonstrates the UI without resetting timers.

The lightweight native helper samples the duration since keyboard/mouse/trackpad input every five seconds for ordinary reminders. After two minutes without input (configurable), counting pauses; reading without input can therefore count as idle. Sleep, display sleep, screen lock, and inactive user sessions also pause it. Active counters are in memory and restart with the helper. If a lock, sleep or display notification is missed, Health Breaks clears the stale pause from the live session state within about 15 seconds. Its menu is built once and updates in place, also while open. No keystrokes, screen contents, app names, activity logs, or health records are collected. Preferences are saved locally.

Each reminder can be disabled or set to 1–240 minutes. Settings also offer optional sound, centered placement, and login startup. The menu bar offers **Pause for One Hour** and resume. Login startup is enabled on first install and preserves your choice on updates; while it is on, launchd restarts the helper if it crashes. Popups are app-owned reminders, so they do not require Notification Center permission and are not suppressed by macOS Focus; pause them from the menu before a presentation or meeting.

The eye prompt follows the [American Academy of Ophthalmology’s 20-20-20 guidance](https://aao.org/eye-health/tips-prevention/should-you-be-worried-about-blue-light). [OSHA’s workstation guidance](https://www.osha.gov/etools/computer-workstations/work-process) describes short work breaks. The stretch and water intervals are adjustable product defaults, not prescribed medical schedules.

### Drop Shelf

Collect items from several apps, switch to the destination, and drag them out when ready. Each open shelf appears on every connected display and stays above normal app windows across desktops, full-screen apps, and Stage Manager. Its display copies share contents, selection, progress, and shelf actions; each keeps its own position and scroll. Closing a shelf closes all its copies into one Recent entry. Connecting or disconnecting a display preserves the shelf and waits for active drags or dialogs to finish before changing its windows.

Run **New Drop Shelf** in Raycast or press **⌥⇧Space** while the helper is running. The shelf appears immediately without activating Drop Shelf (the frontmost app keeps its menu bar) and reuses an open, empty, unnamed shelf instead of creating another. Shake the pointer during a drag, or drop onto its menu-bar icon, to open a translucent floating shelf near the pointer. Add files/folders, plain text, web links, or images. Browser images show an immediate receiving indicator and become real image files: the browser's file promise preserves the original filename and bytes; available image pixels are used next, followed by the image URL. Raw pixels (TIFF) are saved as PNG, and `data:` images are decoded. Image content is validated before saving. If no image can be received, a usable link is retained with an explicit fallback message. Promised files, including multiple files from one drag, are supported; stalled promises and downloads have a 20-second deadline each. Adding a file stores a reference; it leaves the original in place. Dragging out copies the selected items (or the entire compact stack). Expand the shelf for individual selection; Command-click selects multiple items, and dragging any selected item copies the group. Scrolling and selection stay in place as new items arrive. Thumbnails load for the visible rows.

**Space** opens Quick Look; **⌘V** adds the clipboard; **⌘C** copies items; **Delete** removes the selected shelf references (with nothing selected it does nothing, and removing every item asks first); **⌘Z** restores the last removal for ten seconds; **Escape** closes the shelf into Recent. The action menu provides Copy to Folder, Create ZIP, native macOS sharing, Show in Finder, shelf naming/colors, and moving selected references into a new shelf. Pin shelves to retain them in the menu. The ten most recently closed unpinned shelves remain available. Closing a shelf while an import is running keeps that work alive in Recent; pending shelves are protected from eviction until their imports finish. Original files are never deleted when removing shelf items.

**Drop Shelf Settings** controls shake activation, the shortcut, and opt-in login startup. Screenshot Studio's ⌘⇧2 and Clipboard History's ⌘⇧V remain reserved. The helper uses drag events rather than a polling loop. Local storage is under `~/Library/Application Support/Productivity OS/Drop Shelf`, with a 200-item limit per shelf, 30 shelves overall, 1 MiB text items, 20 MiB image items, an 80-megapixel decoding limit, and 200 MiB of saved image data. Image imports use at most two concurrent workers; storage writes and image conversion run off the UI thread. Pending imports reserve shelf capacity, and successful items retain the order in which they were dropped. ZIP operations run through Resource Guard and may wait for memory availability; **Cancel Export** stops them, Quit offers **Stop and Quit**, they time out after ten minutes, and they never block logout, restart or shutdown. File actions run off the main UI thread, one at a time.

This first version covers local shelves and actions. Cloud uploads, watched folders, notch activation, and custom scripts are not included. Shelf state is local and is not encrypted; only add content you intend to retain. Native Share actions send content only when explicitly selected. Updates apply when no shelf, import, export or dialog is open; setup preserves shelf history. If the history file is damaged, it is moved aside with its images and Drop Shelf starts with empty history and a **Show Damaged History in Finder** menu item.

### Clipboard History

Press and release **⌘⇧V** to paste the shown clip immediately, without Enter. Keep ⌘⇧ held and tap **V** (or the arrow keys) to cycle through history; releasing the modifiers pastes your selection. The Flycut-style bezel shows the source app, clip text, and an “N of M” counter. Run **Clipboard History** in Raycast or from its menu to keep the browser open for searching and Enter-to-paste. Start typing to search inline. ⌘C copies; ⌘D toggles a favorite; ⌘S shows favorites; ⌘Delete deletes; Escape clears the search or dismisses. Screenshot Studio keeps **⌘⇧2**. Automatic paste requires macOS Accessibility permission; without it the selected text is copied for manual ⌘V.

A small native menu-bar helper starts at login and checks for clipboard changes every 500 ms (a single change-counter read; it stops while collection is paused, the Mac is locked, or the display sleeps, and keeps running while menus are open). The ⌘⇧V bezel is built ahead of time and appears without a fade-in. Its menu and **Clipboard History Settings** provide pause/resume, app exclusions, a configurable hotkey, login startup, clear history, and quit. Ordinary entries expire seven days after their last copy. Favorites remain until explicitly deleted. Limits are 500 ordinary entries, 100 favorites, 1 MiB per entry, and 16 MiB total text; favorites are never silently evicted. History contains plain text only, preserving whitespace and Unicode exactly.

History is stored locally in `~/Library/Application Support/Productivity OS/Clipboard History/history.sqlite`. Clip text and source labels are AES-GCM encrypted with a key in the login Keychain. There is no cloud sync or telemetry. Clipboard entries marked confidential, temporary, or autogenerated are skipped, as are copies from excluded apps. Unmarked secrets cannot always be identified. App exclusions affect future copies, not existing history. A source label is best-effort attribution. Other installed clipboard managers retain their own independent history and privacy settings.

Collection pauses while locked/asleep, and resuming does not backfill clipboard contents. If history cannot be opened, damaged entries are skipped and removed, and opening is retried automatically on unlock, wake and the next copy (never with a Keychain prompt); the menu shows **History unavailable — Retry Opening History**, plus **Reset History…** (which moves the file aside) only when a reset can help, and it reports shortcut registration problems. Copies that begin and end between sampling intervals may not be recorded. A successful simulated ⌘V does not guarantee every destination app accepts paste. The helper never sends Return or executes copied text as a command.

```sh
"$HOME/.local/bin/resource-guard" run -- npm run build:clipboard-history
bash assets/setup-clipboard-history.sh
"$HOME/.local/bin/resource-guard" run -- npm run test:clipboard-history
```

The installer preserves existing history and startup preferences during updates, which apply automatically when the bezel, Settings and dialogs are closed; launchd restarts the helper if it crashes. To uninstall, quit it and run `bash assets/setup-clipboard-history.sh uninstall`; this preserves encrypted history and its Keychain key. Use Clear History with “Also delete favorites” first if you want saved entries removed. The native tests use isolated databases and pasteboards; the optional live paste check targets only an owned editor fixture and restores the prior clipboard when it has not changed externally.

### Screenshot Studio

Press **⌘⇧2** anywhere to select an area to capture. A small resident helper (installed as a login agent by the setup script) owns that shortcut, so the selector opens instantly without a Raycast round-trip. Open **Screenshot Studio** in Raycast or from the Productivity OS dashboard for the other modes, and optionally assign Raycast hotkeys to **Capture Screenshot**, **Capture Area**, **Capture Window**, **Scrolling Screenshot**, **Copy Text from Screen**, and **Record Short Clip**.

Build and install the native macOS 15+ helper on this Apple Silicon Mac:

```sh
"$HOME/.local/bin/resource-guard" run -- npm run build:screenshot-studio
bash assets/setup-screenshot-studio.sh
"$HOME/.local/bin/resource-guard" run -- npm run build
```

Raycast also installs the bundled helper on first use. Updates never replace a running helper: they apply once Screenshot Studio is idle (no window, capture, recording, pinned image or unsaved document), and until then Raycast keeps using the installed copy. This is a locally ad-hoc-signed app, not a notarized public release. macOS may require Screen Recording permission again after a rebuilt executable is installed. Automatic scrolling additionally needs Accessibility permission; microphone permission is requested only when its recording switch is enabled.

Pressing ⌘⇧2 captures every display in parallel, starting with the one under the pointer; each selector appears as soon as its display is ready, and moving the mouse redraws only the crosshair, outline and size label. If the system capture service does not answer within about 3 seconds, the selection is cancelled with a brief notice and ⌘⇧2 works again immediately. Capture opens quick actions for copy, save, drag, markup, and pinning; Esc there works like the close button. When nothing of its own is open, the resident helper returns focus to the app you were using. Space switches area/window selection; hold Command when releasing a dragged selection to adjust it with arrows before Enter. Shift constrains square selection. Screen capture uses frozen area previews, with previous-region and fixed-size settings remembered between launches.

The native editor keeps six common tools visible. **More** and **Find a tool** expose OCR, QR reading, sensitive-information suggestions, text-aware highlighting, strip removal, image composition, backgrounds, difference comparison, GIF export, and pixel inspection. Drag selected annotations or added images to move them; arrows nudge, Command-arrows resize, Command-D duplicates annotations, Option-drag pans. Control disables snapping or selects a crop region over an added image. Use **Preview Export** to see presentation backgrounds. **Export Options** reports encoded size estimates. Editable `.posshot` projects retain originals; share flattened PNG/JPEG/PDF exports when redactions must be permanent. Blur and pixelation are visual effects, not a guarantee that information is concealed. Automated sensitive-text suggestions require review.

Scrolling supports vertical and horizontal viewports. Automatic mode scrolls the selected region; manual mode lets you scroll and add frames. Both stop when alignment is uncertain and retain the verified result. Keep the target visible and unchanged. Arbitrarily animated or virtualized content is not guaranteed to stitch. Short recordings stop at two minutes, default to 30 fps/1920-pixel long edge with audio off, and support optional system/microphone audio, MP4 trimming/muting, frame extraction, and GIF segments up to 15 seconds. GIF exports use 12 fps and a 1280-pixel long edge.

There are no accounts, uploads, or automatic screenshot history. The only login service is the idle ⌘⇧2 helper; remove it with `bash assets/setup-screenshot-studio.sh uninstall`. Unsaved editing sessions are temporary, with crash recovery on the next launch and a 24-hour expiry (a new capture's recovery copy is written in the background, so a crash in the first fraction of a second can lose that one session). Closed editor windows release their memory, and a recording whose capture the system stops still keeps the recorded part and never blocks new captures, Quit or logout. File drag/share exports remain temporarily available for receiving apps and are cleaned after 24 hours on the next launch. When launched on demand, the app exits once its windows and operations close. The resident helper stays running and frees its capture documents. Pinned click-through images can be unlocked or closed through the temporary pin menu bar item or Raycast.

Decoded image caches share a 512 MiB budget; per-document undo metadata is bounded separately. Large images are limited to 100 megapixels/60,000 pixels per side. These are application budgets, not an OS RAM limit. Native regression tests, real OCR, fixture-window capture, and short recording tests run with `resource-guard run -- npm run test:screenshot-studio`; live tests skip explicitly if Screen Recording permission is unavailable. Public competitive performance claims require further benchmarking.

| Command | Behavior |
| --- | --- |
| Productivity OS | The dashboard: every switch on one screen with its current state. Press ↵ on a row to flip it: Color Filters, Menu Bar Icons, Keep Awake (30m, 1h, 2h, 4h, no limit, or custom), Focus Session, each preset, and Blocked Sites. It opens instantly from the last known state (shared with every command) and refreshes in place; toggles flip immediately and an action reloads only its own row. ⌘R refreshes. |
| Resource Guard | Free RAM by choosing other apps to quit; protect Warp and agent hosts; optionally favor their CPU scheduling; coordinate heavy jobs across sessions. Also opens from the dashboard and the Menu Bar Focus Timer. |
| Block Site | Accepts a domain or HTTP/HTTPS URL; adds a manual block for the bare domain and its `www` variant together (`linkedin.com` blocks `www.linkedin.com` too, and vice versa) and checks macOS resolution of both. Its Undo action reviews removal of only that manual block; other tags stay protected. |
| Unblock Site | Type a blocked domain to review unblocking it and its `www` variant together (`Unblock Site instagram.com`). If neither is blocked it opens the blocked list pre-filtered with what you typed. |
| Blocked Sites | Lists exact domains and all their tags. Unblock opens a delayed review for removing every tag on the selected site and its `www` variant together (browsers move between the two, so unblocking one name alone left the site blocked). Each entry also offers Unblock All for every tag it carries (a preset, all manual blocks, or ending the focus session), Unblock All Sites (delayed review), and Check Block diagnostics. |
| Block Preset | Adds the whole preset in one operation, or removes its tags. Unblocking a preset (here, in the dashboard, or Unblock All in Blocked Sites) also removes the `pomodoro` tag a finished round left on the same sites, so they actually open; manual and other preset blocks remain, and the confirmation names any site they keep blocked. Partially blocked presets offer Block Remaining. |
| Start Focus Session | Blocks a preset or currently blocked domains for 1–1440 whole minutes. Unfinished sessions cannot be shortened or replaced. |
| Quick Focus | Starts a focus session from the search bar with two optional arguments: what to block (a preset, or the currently blocked sites) and minutes. Defaults to Social for 30 minutes. |
| Menu Bar Focus Timer | Menu bar countdown. The background refresh every minute makes one helper call; the other rows refresh when the menu opens. Opens the session form, shows locked actions as “Locked until hh:mm”, offers End Stalled Round… when needed, and has an Unblock Site submenu with per-site and Unblock All entries. It also shows and flips Color Filters and Menu Bar Icons, and opens the dashboard. |
| Toggle Color Filters | Switches the macOS Accessibility → Display → Color Filters setting on or off and shows the new state. The filter type and intensity configured in System Settings are kept. Assign it a hotkey in Raycast for one-keystroke switching; it is also in the dashboard and the Menu Bar Focus Timer. |
| Toggle Menu Bar Icons | Hides or shows every menu bar icon to the left of the Productivity OS divider (`‹`). See [Menu bar icons](#menu-bar-icons). Also in the dashboard and the Menu Bar Focus Timer. |
| Lock Screen and Keep Awake | Locks the screen while the Mac keeps running: starts a keep-awake session that lets the display sleep (no time limit unless minutes are given; it replaces a running session), then locks. It is hidden from the menu bar when Amphetamine is not installed. An optional minutes argument limits the session. Also in the dashboard and the Menu Bar Focus Timer. |
| Start Keep Awake | Starts a keep-awake session with Amphetamine's default duration; if one is already running it says so and leaves it alone. |
| Quick Keep Awake | Starts a session for the hours, minutes and seconds typed inline (seconds round up to a whole minute); all empty means no time limit, and it replaces a running session. A command preference allows the display to sleep. |
| End Keep Awake | Ends the running session. |
| Keep Awake Time Remaining | Shows the time left, or what kind of session is running. |
| Configure Keep Awake | Form to start a session for a number of minutes or hours (remembered between runs), or until a date and time. An empty duration means no time limit; it replaces a running session. |
| Run Setup | Checks setup, shows the installed helper version, and provides the installation command with **Copy Command and Open Terminal** and **Check Again**. With helper v4 it offers **Repair Pomodoro State** when the policy file is damaged. |

Manual, preset, and focus tags are independent. Ending a focus session removes only its blocks; sites with other tags remain blocked. Custom focus uses the currently blocked domains, retaining their existing tags, so those permanent blocks remain when the timer ends.

## Resource Guard

Resource Guard prioritizes keeping Warp and coding agents running. Its main view groups other apps with their helper processes and sorts their estimated memory use largest first. **Quit [App] to Free RAM** asks for confirmation and sends a normal Quit request. Apps can prompt to save work or decline; nothing is force-quit or closed automatically. Memory becomes available after the app actually exits, and macOS assigns it to processes as needed. The displayed estimate is not a promise of how many bytes will be released.

Memory estimates use macOS per-process physical-footprint accounting (including compressed memory), not RSS. Each process is attributed to one app; reparented helpers are matched to their app bundle. Missing measurements are marked incomplete. Totals remain estimates, since shared/system accounting can differ from Activity Monitor. Warp, Codex, Claude, their descendants, their app/terminal hosts, Finder, and Raycast are protected from the Quit action. Protection and the process start identity are checked again immediately before Quit. Some browsers/editors may be protected because they currently host a coding session.

The secondary **CPU Priority** control can favor Warp, Codex, Claude, and their descendants under CPU contention. This changes scheduling only; it does not reserve or free RAM. Install its separate, bounded administrator helper once:

```sh
npm run build:resource-priority
sudo /bin/bash assets/setup-resource-priority.sh install
```

The administrator installer creates a root-owned `resource-priority` executable, an account-specific LaunchDaemon that checks every five seconds, and a sudoers rule limited to its `enable`, `disable`, and `status` commands. The helper only changes nice values for that account's identified coding processes, to at most `-5`; it cannot kill processes, execute arbitrary commands, or accept an arbitrary priority or target PID. It journals original values before applying changes. Turning CPU priority off restores tracked values and observed inherited descendants, while preserving changes made by other tools. A child that becomes orphaned and escapes observation between checks may retain inherited priority until it exits. CPU prioritization cannot speed up remote model inference. To remove CPU priority after restoring tracked settings:

```sh
sudo /bin/bash assets/setup-resource-priority.sh uninstall
```

RAM controls and job coordination do not require administrator privileges. The existing job queue remains an additional safeguard: it delays new heavy local commands when the Mac is under pressure. It does not automatically kill, suspend, or change the priority of any process. It coordinates commands that use the launcher; it cannot impose a hard RAM ceiling or prevent an already-running job or another app from exhausting memory.

Open **Resource Guard → Install Resource Guard** in Raycast, or run:

```sh
npm run build:resource-guard
/bin/bash assets/setup-resource-guard.sh install
```

Installation requires no administrator privileges. It installs one native Swift coordinator as the user LaunchAgent `com.productivity-os.resource-guard`, a launcher at `~/.local/bin/resource-guard`, and marked instruction sections in `~/.codex/AGENTS.md` and `~/.claude/CLAUDE.md` (also the Codex global override file if present). Existing instructions are preserved with timestamped backups. Existing agent sessions can read the updated instruction files; they are never restarted automatically. New sessions load the instructions normally. Project-specific instructions and sandbox permissions can still affect compliance and access to the local socket.

```sh
"$HOME/.local/bin/resource-guard" run -- npm test
"$HOME/.local/bin/resource-guard" run -- /bin/zsh -c 'npm run build && npm run typecheck'
"$HOME/.local/bin/resource-guard" status --json
"$HOME/.local/bin/resource-guard" limit 1
"$HOME/.local/bin/resource-guard" cancel JOB_ID
```

Use the launcher for builds, broad tests, and browser automation. Preserve project-specific worker limits (normally no more than two); the guard does not rewrite command arguments. Do not wrap Warp, Codex, Claude Code, or a long-lived development server. Reuse existing servers. Do not detach or daemonize children inside guarded jobs: a child that deliberately leaves the process group is outside cancellation and accounting. Nested guarded commands in the same group reuse their admission instead of waiting for a second slot.

The default is two heavy jobs across all projects. The coordinator samples every five seconds, blocks starts immediately at warning/critical memory pressure, and blocks when the rolling 15-second CPU average reaches 90% or swap-out rate reaches 10 MiB/s. Admission resumes after 30 seconds with normal pressure, CPU below 80%, and swap-outs below 1 MiB/s. Starts are separated by at least ten seconds; startup also waits for recovery measurements. Unknown measurements or an unavailable process inventory hold new jobs. A missing coordinator causes a new invocation to report an error; an already-queued invocation waits through coordinator outages. Running commands survive coordinator restarts. These are conservative initial thresholds, not guarantees against overload.

The Raycast view refreshes every five seconds. RAM relief and protected apps appear first, followed by optional CPU priority, queued/running jobs, pressure, system CPU, allocated swap, swap-in/out rates, and raw process observations. RSS is resident set size, not Activity Monitor's memory footprint; shared pages can overlap. Observed processes have no cancellation action. Cancelling a guarded job asks for confirmation and sends SIGTERM only to its verified process group; a separate confirmed Force Stop action sends SIGKILL if needed. Process identities include microsecond start times to avoid PID reuse mistakes. An unverified surviving group retains its slot but cannot be cancelled through the guard; inspect it in Activity Monitor. A group's slot remains occupied until its members exit, including when the original leader exits first.

The helper runs independently of Raycast and is nearly free while idle: with no jobs it scans no processes and wakes every five seconds for the resource sample (once a second while jobs exist, checking only their process groups). The process list in `status` is built on demand and reused for two seconds. Waiting `resource-guard run` clients sleep on kernel events instead of polling. A failed state write is logged and retried without stopping the service, and an unreadable `registry.json` is moved aside (`registry.json.corrupt-*`). Its state lives in `~/Library/Application Support/Productivity OS/Resource Guard`, and its socket is in `/tmp/productivity-os-resource-guard-UID`, both restricted to the current user. State stores process identities, executable names, directories, and job timestamps, but not command arguments, environments, or command output. macOS notifications are attempted after 15 seconds of warning/critical pressure, at most once every five minutes; availability depends on macOS notification settings. The Raycast status view works regardless of notification delivery.

To update, rerun the installer or use **Repair or Update Resource Guard**. Updates/removal require an empty queue and no running guarded jobs; a coordinator maintenance lock prevents new admission during the change. To remove:

```sh
/bin/bash assets/setup-resource-guard.sh uninstall
```

Removal unloads the user service and removes its launcher and marked instruction sections. It preserves unrelated instructions, backups, and diagnostic state. It does not cancel running work. The website-blocking helper and menu-bar divider are independent.

## Menu bar icons

macOS has no API for hiding another app's menu bar icon, so Productivity OS uses a divider, the same technique as Hidden Bar: a small agent (`assets/menubar-divider`, source in `native/`) owns one `‹` icon, and expanding it pushes every icon to its left off-screen.

1. Run **Toggle Menu Bar Icons** once. The `‹` divider appears next to Control Center and nothing is hidden yet.
2. Hold ⌘ and drag the icons you want to keep to the right of `‹`. Everything left of it will be hidden. ⌘-drag `‹` itself to move the boundary.
3. Run the command again (give it a Raycast hotkey), or click `‹`, to hide. Run it again, or click the divider (now `›`), to show.

While hidden, the divider stays in place as `›` and pushes the hidden icons off-screen by the width of your widest display; click it, run the command, or use the Menu Bar Focus Timer to show them again. A menu bar that is too full for the notch can hide icons on its own, including ones you meant to keep; hiding some makes room for the rest.

The agent starts on first use and runs from a copy in the extension's support directory until logout, so after a restart all icons are visible until the command is run again. Quitting it (`menubar-divider quit`) restores every icon. The divider position lives in the `menubar-divider` defaults domain.

## Keep awake

The Keep Awake commands and the dashboard's Keep Awake row reproduce the Raycast [Amphetamine](https://www.raycast.com/gstvds/amphetamine) extension by gstvds (MIT) and require the [Amphetamine](https://apps.apple.com/app/amphetamine/id937984704) app, which they drive through its AppleScript dictionary. macOS asks once for permission to let Raycast control Amphetamine.

## Implementation

Only the helper edits `/etc/hosts`. It runs stock macOS Perl in a clean environment, validates all arguments before mutation, and locks the hosts file while reading and writing. Preset updates and confirmed removals use a single locked operation. Legacy one-shot session metadata stays with its hosts entries. Pomodoro checkpoints and pending unblock requests use a root-owned state file beside the helper; checkpoints do not rewrite hosts or flush DNS, and reads during a break do not rewrite the state file. Both IPv4 and IPv6 entries are written. The `status` operation returns the session, Pomodoro and blocks under one lock, so the dashboard and menu bar need one helper call instead of four. The helper waits at most 4 seconds for the lock (then reports BUSY) and kills a focus probe that hangs for 2 seconds, so it always answers inside the clients' timeouts. Termination signals are ignored while the state and hosts files are written. If the state file is missing or damaged, blocks stay in place and only reads, additions and expiry run until **Run Setup → Repair Pomodoro State** moves it aside and rebuilds a paused recovery round over the Pomodoro sites.

The helper preserves bytes outside its exact markers and refuses malformed or duplicate marker sections. Inside the section it accepts only its own entries, comments and blank lines, and stops without writing if it finds anything else, naming the line. The section is removed entirely once it holds no entries or comments. If a file lacks a final newline, adding a section inserts a separating newline. Hosts writes preserve the file inode and permissions; as with other in-place file updates, an abrupt disk or power failure during writing is not crash-atomic. Editors outside this app may not honor its advisory lock.

The helper always targets `/etc/hosts` as root. The scoped sudo rule lets processes running as your account manage blocks, but they cannot edit the installed helper. This is a productivity aid, not tamper-proof access control.

Toggle Color Filters needs no setup and does not use the helper. macOS offers no public API for this setting, so the command calls the undocumented MediaAccessibility/UniversalAccess functions that System Settings uses, through `osascript`; a macOS update could change them, in which case the command reports a failure rather than changing anything.

The Check Block action verifies macOS name resolution, not browser enforcement. A browser VPN/proxy extension can route requests around local resolution even while this check passes.

Hosts blocking applies to exact hostnames, not all subdomains. Block Site and the presets add the bare domain and its `www` variant together; other subdomains must be blocked separately. The Blocked Sites list shows and unblocks exact names. Existing connections, browser DNS caches, VPN/proxy resolution, or alternate hostnames can affect the observed result; close an existing connection or restart the browser when verifying a block. Sleep delays expiration until the Mac wakes.

## UI and navigation

Open **Productivity OS** in Raycast to search all tools. The Productivity OS menu bar also has a **Tools** submenu for Screenshot Studio, Clipboard History, Drop Shelf, and Health Breaks. Existing global shortcuts remain unchanged.

- Screenshot Studio groups capture, text/video, and editing actions. The editor highlights the selected drawing tool, and controls have descriptive accessibility labels and tooltips.
- Clipboard History uses a single Flycut-style bezel with no extra buttons, checkboxes, or field borders. Type to search; ⌘S toggles favorites. Empty searches, empty favorites, and paused collection each explain what to do next.
- Drop Shelf has antialiased rounded corners, a soft drop highlight, and a fanned Dropover-style stack with a count badge. Text and links show as cards, images as thumbnails. Item actions are disabled on an empty shelf, and full truncated filenames appear in tooltips.
- Health Breaks confirms settings saves and uses an opaque, appearance-aware settings background while keeping reminders translucent.
- Raycast views open from a cache shared by every command and refresh in place; the setup check runs only when nothing is cached or a read fails. Views pushed from the dashboard reuse its data, and a refused command launch names the command to enable.
- Unavailable dashboard status reads display **Unavailable**, rather than implying the feature is off. Keep Awake validates duration inline, and Resource Guard prevents overlapping action submissions.

## QA

```sh
"$HOME/.local/bin/resource-guard" run -- npm test
"$HOME/.local/bin/resource-guard" run -- npm run typecheck
"$HOME/.local/bin/resource-guard" run -- npm run test:resource-guard
"$HOME/.local/bin/resource-guard" run -- npm run build:check
npm run lint          # ESLint + Prettier + manifest validation (manifest check needs network)
npm run fix-lint      # auto-fix formatting and lint issues
```

Native suites are available as `test:health-breaks`, `test:posture`, `test:clipboard-history`, `test:drop-shelf`, `test:screenshot-studio`, and `test:resource-guard`; run each through Resource Guard. Native tests use temporary data and render fixture windows. The Drop Shelf and Screenshot Studio suites also have screen-free subsets (`DROP_SHELF_TEST_SCOPE=headless`, `STUDIO_QA_HEADLESS=1`) that open no windows and capture nothing. `npm test` also runs `tests/setup-scripts.test.py` (every helper installer against a temporary HOME with launchd, Launch Services and the running helpers stubbed) and `tests/native-launcher.test.cjs` (install, update, busy and supervised-start paths of the Raycast launchers). Real clipboard paste is opt-in with `QA_LIVE_PASTE=1`; it is skipped by default to leave the working clipboard untouched. See [the UI/UX audit](../tests/UI-UX-QA.md) for coverage and limitations.

`tests/ui.test.cjs` renders every command outside Raycast and presses its actions: the Raycast API is replaced with stand-ins, website blocking runs through the real bundled helper on a temporary hosts file, and color filters, the menu bar agent and Amphetamine are simulated. It covers each view's states (not set up, empty, partial, active), every dashboard switch, the forms' validation, and the HUD and toast text.

Tests use temporary hosts files, never the system hosts file, and cover overlapping tags, IPv6, concurrent edits, focus replacement rejection/expiry, cooldown and scope validation, Pomodoro lifecycle, non-ASCII labels, invalid inputs, malformed markers, legacy entries, adoption of a Site Blocker section, CRLF files, URL normalization (including IDN and non-HTTP schemes), countdowns, Amphetamine duration parsing and formatting, and preservation of unrelated bytes. A Node test also asserts that the JS domain regex in `src/lib.ts` matches the Perl regex in `assets/blocker.sh`. Helper tests refuse to run as root. `npm run lint` fails on the `author` field until it matches a Raycast account handle; that only matters for store publishing.

For a manual helper test as your normal user:

```sh
hosts=$(mktemp)
printf '127.0.0.1 localhost\n' > "$hosts"
HOSTS_FILE="$hosts" ./assets/blocker.sh add example.com manual
HOSTS_FILE="$hosts" ./assets/blocker.sh list
rm "$hosts"
```

After installation, verify in Raycast: block and unblock a disposable hostname; toggle a preset overlapping a manual block; start a one-minute focus session, quit Raycast, and confirm the focus-only entries disappear within approximately 30 seconds of expiry while manual entries remain.

## Uninstall

Follow the [component-by-component removal guide](uninstall.md). Clear website blocks before removing their privileged helper.
