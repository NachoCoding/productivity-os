# Installation and updates

[Documentation index](README.md)

## Requirements

- Apple Silicon Mac, macOS 15 or later. Native app build scripts target `arm64-apple-macos15.0`.
- Raycast installed and running.
- Node.js 22.22.2 or later and npm, as required by the locked Raycast API package.
- Xcode Command Line Tools (`xcode-select --install`) for Swift and signing tools.
- Python 3 for tests.
- Optional: Amphetamine for keep-awake commands; a built-in MacBook camera for Posture Coach.

This is a source installation. There is no bundled binary download or notarized release.

## 1. Get the source

```sh
git clone https://github.com/NachoCoding/productivity-os.git
cd productivity-os
npm ci
```

## 2. Bootstrap Resource Guard

If Resource Guard is already installed, reuse it and skip this bootstrap. Do not replace the service while another session has queued or running work.

For a fresh machine only, compile the coordinator once, then install it:

```sh
npm run build:resource-guard
bash assets/setup-resource-guard.sh install
"$HOME/.local/bin/resource-guard" status --json
```

This unprivileged installer adds a user LaunchAgent, the launcher at `~/.local/bin/resource-guard`, and marked resource-coordination instructions to Codex/Claude instruction files. It backs up existing files and preserves unrelated instructions. The initial coordinator build is the bootstrap exception; use the guard for subsequent builds and tests.

## 3. Build the helpers

Run these sequentially; the guard can wait for machine capacity. Do not bypass a waiting or unavailable guard.

```sh
"$HOME/.local/bin/resource-guard" run -- npm run build:helper
"$HOME/.local/bin/resource-guard" run -- npm run build:focus-probe
"$HOME/.local/bin/resource-guard" run -- npm run build:health-breaks
"$HOME/.local/bin/resource-guard" run -- npm run build:clipboard-history
"$HOME/.local/bin/resource-guard" run -- npm run build:drop-shelf
"$HOME/.local/bin/resource-guard" run -- npm run build:screenshot-studio
"$HOME/.local/bin/resource-guard" run -- npm run build
```

Native build scripts create app bundles in `assets/`. They may create a local code-signing identity named **Productivity OS Local Signing** in your Keychain to preserve privacy grants across rebuilds. Some helpers use ad-hoc signing. This is local signing, not Apple notarization or a downloaded certificate.

## 4. Import into Raycast

Use Raycast's **Import Extension** command and select this repository. Alternatively run `npm run dev` for development. Development servers remain outside the Resource Guard queue; reuse one for this checkout.

Open **Productivity OS**. Native tools install their built helper on first use. You can also install them explicitly:

```sh
bash assets/setup-health-breaks.sh install
bash assets/setup-clipboard-history.sh install
bash assets/setup-drop-shelf.sh install
bash assets/setup-screenshot-studio.sh install
```

Installers preserve stored preferences/data. Login behavior differs by helper: check its Settings. See [permissions](privacy-and-permissions.md) before enabling capture, automatic paste, or posture monitoring.

## 5. Enable optional privileged features

Website blocking and protected Pomodoro website rules need the root-owned helper:

```sh
sudo /bin/bash assets/setup.sh
```

This installs the blocker, focus-state probe, a scoped sudoers rule, and a system expiry service. Open **Run Setup** to verify it. It is not needed for screenshots, clipboard history, or ordinary break reminders.

Optional CPU scheduling preference is a separate helper:

```sh
"$HOME/.local/bin/resource-guard" run -- npm run build:resource-priority
sudo /bin/bash assets/setup-resource-priority.sh install
```

Enable or disable CPU Priority in Resource Guard. It changes scheduling and does not reserve memory.

## Update

Pull source changes, run `npm ci` when dependencies change, then rebuild affected helpers and the extension through Resource Guard. Do not overwrite your own uncommitted work when pulling.

Native launchers compare build IDs. An idle installed helper updates automatically on the next command; a busy helper defers until its windows, capture, export, or calibration are closed. Rebuilding with a different signing identity can require granting privacy permissions again.

After blocker/focus-probe changes, rerun `sudo /bin/bash assets/setup.sh`. After Resource Guard changes, build it through the existing guard, let all queued/running jobs finish, then run its installer **outside the queue**. An installer cannot replace the coordinator while its own guarded job is active.

## First-run check

Open the dashboard, capture a disposable image, copy harmless text into Clipboard History, and create a shelf with a temporary file. Check each feature independently. For website blocking, use a disposable domain and finish the unblock review afterwards. Do not enable Posture Coach until you want to grant camera access and calibrate.
