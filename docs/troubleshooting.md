# Troubleshooting

[Documentation index](README.md)

## A native helper is missing

A source checkout contains build scripts, not app bundles. Run the matching `build:*` script through Resource Guard, then reopen the command. Build the extension after changing its bundled assets. Use **Run Setup** for website-helper diagnostics.

## Build fails

Check `node --version`, `xcode-select -p`, and `swift --version`. The locked Raycast package needs Node 22.22.2 or later; native apps target Apple Silicon and macOS 15+. Run `npm ci` from the repository root. Preserve the first compiler error when reporting a failure.

A Keychain prompt during a native build may come from creating/using the local signing identity. Changing the identity can invalidate existing macOS privacy grants.

## Capture, paste, or scrolling fails

Check Screen Recording or Accessibility permissions for the helper involved. Relaunch that helper after granting permission. Clipboard History falls back to copying for manual paste without Accessibility. Scrolling capture can stop when alignment is uncertain or page content moves independently; use manual scrolling or smaller captures.

A shortcut conflict can prevent registration. Check the helper's Settings and other screenshot/clipboard utilities before assigning another shortcut.

## A helper says “Quit X to finish updating”

Close its windows, capture, export, settings, and calibration, then quit that helper normally and reopen the command. The updater deliberately preserves active work. Installer exit code 75 means busy, not permission denied. Do not force-quit a helper with unsaved work to make an update proceed.

## Websites still load

Use **Blocked Sites → Check Block** to verify macOS name resolution. Hosts rules cover exact hostnames; the bare domain and `www` are paired, but other subdomains are separate. Existing connections, browser DNS caches, VPN/proxy routing, and alternate hosts can bypass the expected result. A successful resolver check does not prove browser enforcement.

## A website will not unblock

Complete the one-minute review. Unfinished Pomodoro rounds remain protected even if paused or restarted. Use **End Stalled Round…** only when it is offered by the application. For damaged state, use **Run Setup → Repair Pomodoro State**; do not erase state or edit around the lock.

## Resource Guard is waiting

```sh
"$HOME/.local/bin/resource-guard" status --json
```

Read the reason and queued jobs. New starts can wait for memory pressure, CPU saturation, swap activity, capacity, or unavailable measurements. Let the queue wait; continue lightweight editing. Never wrap an agent host or long-running dev server in the queue.

If the service is unavailable, inspect its LaunchAgent:

```sh
launchctl print "gui/$(id -u)/com.productivity-os.resource-guard"
```

Use **Repair or Update Resource Guard** once no queued or running jobs remain. Do not remove another session's work. A restart can reconcile surviving groups; do not delete the registry to release slots manually.

## Clipboard History cannot open

Unlock the login Keychain, then use **Retry Opening History**. If offered, **Reset History…** moves the database aside; review the action before using it. App exclusions do not remove past entries. A copy that starts and ends between sampling intervals may not enter history.

## Posture Coach does not start

It begins only after explicit enablement and successful calibration. Check camera permission and built-in camera availability. Keep face and both shoulders visible; recalibrate after moving your seat or display. Camera contention, idle/lock/sleep, paused reminders, or resource budget limits can pause monitoring. Pomodoro state does not control posture monitoring.

## Color Filters or keep awake fails

Color Filters uses undocumented macOS functions, which can change with OS updates. Amphetamine must be installed for keep-awake controls; allow Raycast to automate it.

## Raycast lint reports an author error

The manifest author must match a Raycast account for store publishing. GitHub source publication is separate. Report ESLint/formatting failures separately from remote manifest validation; do not silently change the author to bypass validation.
