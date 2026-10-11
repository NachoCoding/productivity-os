# Development

[Documentation index](README.md)

## Setup

Follow [Installation](installation.md), then use `npm run dev` for Raycast development. Keep one development process for a checkout. TypeScript lives in `src/`, Swift helpers in `native/`, and build/install scripts in `assets/`.

Do not commit generated app bundles, executables, `dist/`, local databases, signing material, or agent settings. Command PNGs are included; regenerate them with `npm run build:icons` only when needed.

## Validation

Run heavy jobs through Resource Guard. Keep tests/builds sequential unless available capacity supports two concurrent jobs; do not exceed two workers.

```sh
"$HOME/.local/bin/resource-guard" run -- npm run typecheck
"$HOME/.local/bin/resource-guard" run -- npm test
"$HOME/.local/bin/resource-guard" run -- npm run build:check
```

`npm test` covers blocker behavior with temporary hosts files, isolated native installer fixtures, TypeScript clients, and simulated Raycast UI interactions. It does not prove live permissions, capture, camera accuracy, or Raycast integration.

| Script | Scope |
| --- | --- |
| `test:resource-guard` | Queue policy, installer, process accounting, service recovery |
| `test:health-breaks` | Reminder/Pomodoro models and native behavior |
| `test:posture` | Posture model and native fixtures |
| `test:clipboard-history` | Encrypted storage, shortcuts, resilience |
| `test:drop-shelf` | Imports, storage, rendering, drag/drop |
| `test:screenshot-studio` | Capture/editor models and native rendering |

Invoke the selected suite through Resource Guard, for example `"$HOME/.local/bin/resource-guard" run -- npm run test:resource-guard`.

For screen-free native subsets:

```sh
DROP_SHELF_TEST_SCOPE=headless "$HOME/.local/bin/resource-guard" run -- npm run test:drop-shelf
STUDIO_QA_HEADLESS=1 "$HOME/.local/bin/resource-guard" run -- npm run test:screenshot-studio
```

Live clipboard paste is opt-in with `QA_LIVE_PASTE=1`. Do not enable it during another person's active work. Native suites may create fixture windows or require system permissions. See [UI/UX QA](../tests/UI-UX-QA.md) and feature-specific QA files in `tests/`.

`npm run lint` combines ESLint, formatting, and network-backed Raycast manifest validation. `npm run fix-lint` changes files; review its output. The manifest author may need a valid Raycast handle before store publication. `npm run publish` publishes to the Raycast store—it is not the GitHub push workflow.

## Changing a feature

1. Edit its client/native component and related documentation.
2. Run targeted tests, then typecheck/build when relevant.
3. Build changed native helpers before rebuilding the extension.
4. Verify the feature in Raycast with disposable fixtures.
5. Check that an update preserves active windows and stored data.

Native updates must retain the idle/busy protocol and build identity checks. Keep privileged operations bounded; never replace the hosts helper with arbitrary shell execution. Tests must not edit the real hosts file or reset another session's state.

## Publishing source

Review staged files for credentials and personal data, confirm tests, and push source to GitHub. Compiled binaries require a separate distribution/signing decision. A public source commit is not a notarized release or a Raycast Store submission.

## Initial source publication checks — 2026-10-11

- TypeScript type checking passed.
- `npm test`: 53 blocker tests, 14 installer tests, and 106 Node tests passed; one optional real-bundle installer test was skipped.
- `npm run build:check` passed using the existing locally built native assets.
- Local documentation links and referenced npm scripts were checked.

Native Swift suites, clean-machine installation, camera/capture permission flows, and store publication were not rerun for this documentation/source-publication change. Historical QA reports in `tests/` describe earlier work and do not expand these checks.
