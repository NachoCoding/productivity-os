# Focus and posture verification

Evidence recorded on 2026-10-08. Automated and installed-app results are separated below; remaining manual checks are listed explicitly.

| Check | Completed result | Scope |
| --- | --- | --- |
| Blocker helper | 36 tests passed | Cooling-off delay, reason requirement, batch scope, active-focus hard lock, restart handling, unblocking during a break without losing round count, and reblocking for the next focus. |
| Node tests | 50 tests passed in the final full npm run | Client and UI contracts, real-helper temporary-hosts integration, guarded reason/wait flow, and Pomodoro focus/break/ready status. |
| Native Health Breaks | 194 checks passed after calibration repair | Timer/reminder regressions plus durable calibration results, preserved previous baseline, actionable dropout guidance, real notice display with fake observations, and camera-free Test Reminder including preview Snooze isolation. |
| Posture core | 129 checks passed after the ten-second timing update | Monitoring eligibility, tracking guidance, bounded calibration, stale frame rejection, stability checks, no reminder at 9.99 seconds and a reminder at ten seconds, cooldown, scheduling and resource bounds. No camera access. |

A 120-second `agent-load-check` during build/test work recorded system CPU averaging 6.3% and peaking at 13.8%, normal memory pressure, 1.1 MiB swap-in, and no swap-out. Allocated swap stayed at 935.6 MiB. These are system-wide measurements during development checks, not measurements of the installed app or active camera. RSS must not be presented as physical memory footprint.

## Initial Pomodoro installed-app check

The signed app, Raycast assets, privileged helper v3, and focus probe were installed. The three HealthBreaks binaries have matching hashes. Existing Health Breaks preferences were preserved, and posture remains disabled without saved posture preferences. After Raycast's CLI build-refresh notification, launching the new Pomodoro command through its Raycast link opened the installed native controls successfully.

A disposable `.invalid` hostname was used for a one-minute focus round and one-minute break with the installed helper and native app. The app advanced through `focus → shortBreak → ready`; reopening controls did not restart the round. DNS resolved the test hostname to a blocked loopback address during focus, and direct unblocking returned `FOCUS_LOCKED`. During the break, immediate unblock confirmation returned `UNLOCK_NOT_READY`. Confirmation succeeded after the 60-second cooldown, preserving the completed-round count. The test then stopped the timer, returned it to idle, and restored `/etc/hosts` byte-for-byte. Existing site selections and reminder preferences were not changed.

The installed native process was sampled with `proc_pid_rusage`, first for a 15-second idle baseline and then for approximately 120 seconds through focus and break. The controls were closed during sampling and the camera remained off.

| Measurement | Idle baseline | Focus and break |
| --- | --- | --- |
| Average CPU, percent of one core | 0.002% | 0.023% |
| Peak physical memory footprint | 11.42 MiB | 23.16 MiB |
| Peak RSS, reported separately | 61.66 MiB | 87.53 MiB |

Peak physical footprint increased by approximately 11.7 MiB from the initial baseline. This is a short timer-only measurement, not an active-camera result. The periodic helper subprocesses are not included in these per-process figures.

Evidence: `/tmp/productivity-focus-install-check.json`, `/tmp/productivity-focus-live-check.log`, and `/tmp/productivity-focus-live-result.json`.

## Independent posture update

The updated signed app and Raycast extension are installed. Source, installed, packaged, and Raycast HealthBreaks executables match SHA-256 `a301a82f678b0453fe613171a75ba368cab1ba9229b7cadf074c86e83367b994`. Native settings show that posture works independently of Pomodoro, and Enable & Calibrate is available with the timer manually paused. The existing paused timer, all saved preferences, and hosts file were preserved exactly during installation. One HealthBreaks process is running. This installation check did not perform camera calibration or validate real-world detection accuracy.

Evidence: `/tmp/posture-independent-install-check.json` and `/tmp/posture-independent-build.log`. The pure suite passed 107 checks in `/tmp/posture-independent-checks.log`. The first native attempt failed an existing settings-value assertion after a UI wait; its initial value is now checked synchronously before yielding to user input. The subsequent native run passed all 165 checks in `/tmp/posture-independent-native-final.log`, with no compiler warnings.

The subsequent calibration repair is installed with SHA-256 `7556907dee020cdc91c2a059be7895943734314d7661c907c1e8b5076a35fe96` matching all four app copies. It adds a calibration-only preview that defaults on, bounded sample collection tolerant of brief tracking gaps, specific tracking guidance, and a lasting calibration result. Recalibration preserves a previously saved baseline until a replacement is saved. **Test Reminder** works without enabling coaching or using a camera. The installed test button produced a popup with the expected preview text, verified through accessibility. User-visible popup confirmation and actual camera calibration remain separate live acceptance checks.

The 134 pure checks, 194 native checks, signed build, and extension packaging passed without warnings. Preferences, current Pomodoro state, and hosts were preserved during installation. Evidence: `/tmp/posture-setup-repair-build.log`, `/tmp/posture-setup-repair-final.log`, and `/tmp/posture-setup-repair-install.json`.

The requested ten-second deviation threshold is now installed. Detector timing and the visible countdown share one constant. The updated pure suite passed 129 checks and the native suite passed 194, including no popup at 9.99 seconds and an actual popup at ten seconds with simulated observations. Normal low-rate camera sampling is unchanged, so real reminders appear on the next valid observation once the threshold is met. Saved preferences were preserved, and all four signed app copies match SHA-256 `449949781438c97326db4387dc751fda815e23374dfa3658d3b0bbca0826d7bf`. Evidence: `/tmp/posture-10s-checks.log`, `/tmp/posture-10s-build.log`, and `/tmp/posture-10s-install-check.json`.

## Remaining installed-app checks

- Start focus through Raycast and the menu bar; verify the same plan opens, the countdown stays responsive, and configured sites are blocked in a fresh browser request. Reopening controls must not restart the round.
- Pause/resume, lock/unlock, sleep/wake, switch users, and quit/reopen Health Breaks. Confirm focus time is not credited while paused or away, saved progress survives restart, and website blocks remain protected. A temporary monitor failure should recover without overriding manual pause.
- Finish a focus round. Verify the quiet break notice, short/long break sequence, completed-round count, and break-ended notice. The next focus must wait for an explicit action. Test changed durations on the next round.
- Attempt every normal unblock path during focus: individual sites, presets, batches, all sites, and ending focus. Each must remain locked. During a break or outside focus, verify the 60-second delay and required reason, expired/changed-scope rejection, and preservation of unrelated blocks. Unblocking during a break must preserve the Pomodoro round count; the next focus must restore its configured site protection.
- Stop future cycles during a break and verify that existing website blocks remain until the deliberate unblock flow completes. Check browser behavior after the helper updates hosts and refreshes DNS.
- Confirm existing eye/stretch/water reminders and their saved settings still work. Opening posture settings must not request permission or turn on the camera.
- Choose **Test Reminder** with posture off and verify a visible nonactivating popup without camera permission, camera capture, or preference changes. A successful popup test does not establish posture-detection accuracy.

## Optional camera acceptance

Camera accuracy and active-camera performance have **not been measured**. The user must explicitly choose **Enable & Calibrate** while awake and unlocked. The preview defaults on only for calibration and can be hidden. Verify a saved result or an actionable failure within about 30 seconds, retained progress after brief tracking gaps, and preservation of an old baseline when **Recalibrate** is cancelled or fails. After successful setup, posture monitoring runs while the Mac is actively used, independently of Pomodoro. Health Breaks' one-hour pause still suppresses automatic posture monitoring while allowing explicit calibration. Follow the [posture QA checklist](../posture/QA.md) for setup completion, reminders without a timer, permission cancellation, visibility, false prompts, contention, and camera shutdown.

The [read-only profiler](../posture/profile.py) reports per-process CPU and physical footprint against a pre-capture baseline; it never launches the app or enables a camera. Measure on the actual 16 GB Mac, including repeated stop/resume, before claiming the 5% single-core CPU and 150 MiB additional-footprint targets. Record throttled or budget-paused status as such rather than reporting a performance pass.

TypeScript, targeted ESLint, extension packaging, signed app verification, Info.plist validation, and bundled preset comparison passed.

Build/test logs:

- `/tmp/productivity-focus-final-checks.log`
- `/tmp/productivity-focus-extension-build.log`
- `/tmp/health-pomodoro-native-tests.log`
- `/tmp/health-pomodoro-build.log`
- `/tmp/productivity-focus-load-check.log`
- `/tmp/posture-calibration-checks.log` (standalone-calibration update: 264 checks, signed build, no compiler warnings)

Pre-install signed HealthBreaks SHA-256: `7e5af20afc14c7eaa321eb41c9e8dd7f75b4ec7da900103c5c149d6e1f0090db`.
