# Posture coaching checks

The automated tests never request camera permission, discover camera devices, or capture frames:

```sh
"$HOME/.local/bin/resource-guard" run -- /bin/bash tests/posture/run.sh
```

Camera verification requires the user's explicit action in the installed app. It has not been performed by the automated suite. While your Mac is awake and unlocked, open **Posture Coach** and click **Enable & Calibrate**. Setup and ongoing reminders work independently of Pomodoro, including when no timer is running or focus is paused. The preview defaults on during calibration and can be hidden with its checkbox; it closes when calibration ends. Keep both shoulders and the face visible. Front-camera geometry is a relative reminder heuristic; it cannot diagnose spinal alignment, and some camera angles or framing may never provide confident shoulder landmarks.

The native Health Breaks suite uses injected permission responses and a fake capture implementation to exercise the actual setup buttons, permission cancellation, calibration completion, retained baselines after failed or cancelled recalibration, durable results, tracking guidance, Health reminder pause/resume, and a real nonactivating notice without a Pomodoro. Its empty preview session never has inputs and never starts capture. It also exercises **Test Reminder** while coaching is off and during calibration. Run it through Resource Guard with `/bin/bash tests/health-breaks/run.sh`. These checks do not validate real camera accuracy.

Calibration runs the built-in camera at 5 fps. Once a baseline is saved, monitoring switches the running camera to the slowest frame rate its active format supports (never below 1 fps), because it analyses only one frame every three to five seconds; the status line reports the rate (for example “camera 1 fps”). Posture eligibility updates every five seconds with the reminder tick and on lock, sleep, pause, or opening Posture Coach, not every second. The frame-rate choice is a pure function covered by `tests/posture/run.sh`; the actual camera rate is verified manually below.

Verify these behaviors manually:

- After calibration, the status shows a monitoring rate below 5 fps when the camera supports one, and checks still run every three seconds. Recalibrating returns to 5 fps until the new baseline is saved.

- Deny permission: the timer continues, with an actionable posture status and no repeated permission prompt. Turn coaching off: the camera indicator goes out.
- Before enabling coaching, choose **Test Reminder**. A quiet popup must appear without taking keyboard focus, requesting camera permission, enabling coaching, or saving a baseline. Dismiss it and confirm posture remains off. This verifies reminder delivery only; it must not report camera calibration as successful.
- Calibrate for at least five seconds without running Pomodoro. Sample progress must describe collection, never completion before the baseline is actually saved. On success, a durable success result appears, the preview closes, **Recalibrate** replaces **Enable & Calibrate**, and ordinary monitoring begins immediately from the saved calibration. Starting, pausing, or ending Pomodoro and entering a timer break must not stop posture reminders.
- During setup, briefly obscure a shoulder and restore it. Show concrete framing guidance and retain recent useful observations through a brief dropout. Progress may expire after a sustained gap or inconsistent pose. No frames, unsteady samples, and repeated tracking issues must finish within about 30 seconds with a durable explanation; subsequent ordinary activity updates must not erase it.
- After successful setup, choose **Recalibrate** and cancel by closing settings. Reopen: the previous baseline is still saved and eligible monitoring resumes. Repeat with a calibration timeout. Keep the previous baseline and visible failure explanation, and never silently replace it with a partial or unsteady attempt. With no previous baseline, a failed attempt must leave monitoring stopped.
- Choose Health Breaks' **Pause for One Hour**: automatic posture monitoring stops. Explicit calibration still works while Health reminders are paused; when it finishes, save the baseline and stop the camera until Health reminders resume. Pausing Health reminders midway through calibration must let explicit setup finish without restarting monitoring. No-frame or unsteady calibration must time out within about 30 seconds, including when no observation callbacks arrive.
- Cover either shoulder or turn away: tracking becomes unknown and never nudges. Moving the screen or seat should request recalibration when the framing changes substantially.
- After calibration, with no Pomodoro running, lower the head relative to the calibrated position for at least 10 seconds: status shows a reminder countdown, then one silent, nonactivating reminder appears on the next tracking sample. Returning near baseline for ten seconds clears the event. Repeated reminders respect the five-minute cooldown; Snooze stops capture for five minutes.
- During either monitoring or explicit setup, idle for two minutes, lock, sleep, switch user, or close the laptop lid: capture stops and late observations cannot show a reminder or save calibration. Return to active use: valid saved calibration can resume without starting Pomodoro.
- Let another app use the built-in camera: posture pauses without switching to an external or Continuity camera. Release it: posture may resume while the Mac is active and Health reminders are not paused. With no built-in camera available, the feature stays unavailable.
- Close settings, turn coaching off, or lock the Mac during a pending permission request: a later grant must not resurrect cancelled calibration. Closing settings during calibration also cancels setup. Outside calibration, closing settings does not disable an already calibrated coach.

Measure on the actual 16 GB Mac before claiming the active-camera performance target. Start with a fresh Health Breaks process and posture off so Vision caches are included in the added memory cost. For sustained monitoring measurements, remain actively using the Mac and leave Health reminders unpaused; no Pomodoro is required. Pass its PID to the read-only profiler, then use **Enable & Calibrate** yourself when the profiler announces the measurement phase:

```sh
python3 tests/posture/profile.py --pid HEALTH_BREAKS_PID --baseline-seconds 30 --seconds 120
```

During the same active workload, also run:

```sh
"$HOME/.local/bin/agent-load-check" --seconds 120
```

Record CPU as percent of one core, incremental physical footprint against the original pre-capture baseline, system memory pressure, swap activity, app status, and whether calibration or monitoring was active. RSS is reported separately and is not physical footprint. Targets are at most 5% of one core and 150 MiB added physical footprint; these are acceptance targets, not measured claims. The runtime gate samples its own process every 30 seconds, slows analysis from every three to every five seconds after two excessive windows, and pauses coaching if two more windows exceed the targets. Resource pressure and serious thermal load also pause capture. Repeated pause/resume must not raise the original memory baseline.

Confirm menu/timer responsiveness, no growing camera/model allocations over several idle/active and Health pause/resume transitions, and no new on-disk images or network activity. Do not run camera-enabled QA without the user's explicit opt-in. Do not install or activate an app solely to run this script.
