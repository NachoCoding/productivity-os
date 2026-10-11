# Architecture

[Documentation index](README.md)

## Components

| Location | Responsibility |
| --- | --- |
| `package.json` | Raycast command manifest, dependencies, build/test scripts |
| `src/` | TypeScript/React commands, dashboards, validation, cached reads, native clients |
| `native/` | Swift applications, resource coordination, focus-state probe, menu bar divider |
| `assets/` | Installers, build scripts, blocker, preset data, and command icons |
| `tests/` | Isolated helper/client tests, Swift suites, fixture windows, and manual QA notes |

```mermaid
flowchart TD
    R[Raycast commands] --> C[TypeScript clients and shared cache]
    C --> N[Native launcher: build ID and idle checks]
    N --> A[User Swift apps]
    C --> G[Resource Guard user service]
    C --> B[Root-owned website blocker]
    B --> H[/etc/hosts and focus state]
    B --> P[Focus-state probe]
    C --> K[Amphetamine via AppleScript]
    G --> J[Admitted local command groups]
```

## Native apps

Screenshot Studio, Clipboard History, Drop Shelf, and Health Breaks run outside Raycast so capture, floating windows, shortcuts, and reminders can keep working independently. Installers copy built bundles into the user's Applications directory and manage feature-specific user LaunchAgents. URL commands and client wrappers provide bounded launch/action interfaces.

`src/native-launcher.ts` coordinates installs and updates. Build IDs distinguish the bundled and installed versions. Idle-aware updates avoid replacing a helper while it owns active work. A busy app defers its update rather than discarding a document or capture. See each setup script for login defaults and lifecycle details.

Health Breaks also owns the Pomodoro UI and optional Posture Coach. The privileged blocker remains authoritative for protected website rules and focus state; the native app does not directly edit hosts.

## Website-blocking boundary

`assets/blocker.sh` is installed root-owned. Its scoped sudoers rule exposes bounded operations, rather than arbitrary root commands. It validates domains/tags, locks reads and writes, preserves unrelated hosts content, and writes IPv4 and IPv6 entries. A system LaunchDaemon runs expiry work independently of Raycast.

The focus probe reads session/idle state. Root-owned Pomodoro checkpoints avoid rewriting hosts for every tick. Damaged state preserves blocks until an explicit repair. Hosts writes preserve the inode but are not crash-atomic; external editors may ignore the advisory lock.

## Resource coordination

Resource Guard is an unprivileged Swift service with a per-user socket and persistent process identities. Its launcher admits heavy commands into a shared queue, tracks process groups, and gates new starts using pressure, CPU, and swap activity. Verified job cancellation applies to that job's group only. It cannot bound memory for arbitrary apps or detached children.

The separate CPU-priority helper changes scheduling for identified coding processes. App Quit controls remain explicit user actions. See [Resource Guard](user-guide.md#resource-guard) for thresholds, accounting limits, and recovery behavior.

## State and concurrency

Raycast views share cached state and refresh in place. Native apps own their local data; build outputs are reproducible artifacts, not source-controlled state. Tests use temporary directories and simulated system interfaces where possible. Native render/capture suites require macOS and may need explicit permissions.

See [permissions and data](privacy-and-permissions.md), [development](development.md), and the feature-specific Swift source for detailed boundaries.
