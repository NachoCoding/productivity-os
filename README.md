# Productivity OS

A toolkit I built for working on a Mac: focus sessions, screenshots, clipboard history, floating file shelves, break reminders, and resource controls for coding with agents.

Built with TypeScript, Raycast, and native Swift helpers. By [Nacho](https://github.com/NachoCoding).

## What it does

| Tool | What you get |
| --- | --- |
| Focus | Pomodoro, timed website blocking, and deliberate unblock reviews |
| Screenshot Studio | Area/window capture, annotations, OCR, scrolling screenshots, and short recordings |
| Clipboard History | Searchable local text history, favorites, and quick paste |
| Drop Shelf | Floating shelves for files, images, text, and links |
| Health Breaks | Eye, stretch, and water reminders; optional camera-based posture reminders |
| Resource Guard | A shared queue for heavy coding jobs, app memory estimates, and optional CPU priority |
| Desktop controls | Menu bar icon hiding, Color Filters, and Amphetamine keep-awake commands |

## Install

**Source release for Apple Silicon Macs running macOS 15 or later.** Requires Raycast, Node.js 22.22.2 or later, and Xcode Command Line Tools. Python 3 is needed for tests. Amphetamine is optional and only needed for keep-awake controls.

```sh
git clone https://github.com/NachoCoding/productivity-os.git
cd productivity-os
npm ci
```

Next, follow [Installation](docs/installation.md) to build the native helpers and import the extension into Raycast. The repository does not include compiled apps or a notarized installer. Some features need macOS permissions or a separate administrator setup step.

## Start here

Open **Productivity OS** in Raycast for the dashboard. Try **Start Pomodoro**, **Screenshot Studio**, **Clipboard History**, or **New Drop Shelf**. Configure each feature before relying on its shortcuts or login behavior.

- [Installation and updates](docs/installation.md)
- [User guide](docs/user-guide.md)
- [All commands](docs/commands.md)
- [Resource Guard](docs/user-guide.md#resource-guard)
- [Permissions and local data](docs/privacy-and-permissions.md)
- [Troubleshooting](docs/troubleshooting.md)
- [Uninstall](docs/uninstall.md)
- [Architecture](docs/architecture.md)
- [Development and tests](docs/development.md)

## Project status

This is a personal toolkit shared as source. Native build scripts currently target Apple Silicon; Intel Macs and Windows are not supported by this build workflow. A successful build does not replace testing permissions, shortcuts, and capture behavior on your own Mac.

Website blocking is a focus aid, not access control. Resource Guard coordinates participating jobs; it does not enforce a hard memory cap. Clipboard and screenshot tools handle content you select or copy—read [how each feature stores data](docs/privacy-and-permissions.md).

## Contribute

See [CONTRIBUTING.md](CONTRIBUTING.md). Report reproducible bugs through [GitHub Issues](https://github.com/NachoCoding/productivity-os/issues), without private clipboard contents, screenshots, or credentials.

## License and credits

[MIT](LICENSE). Keep-awake integration credits the Raycast Amphetamine extension by gstvds. See [third-party notices](THIRD_PARTY_NOTICES.md). Raycast, Amphetamine, and Apple frameworks are separate products and retain their own terms.
