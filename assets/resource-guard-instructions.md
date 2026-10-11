## Resource Guard

- Keep Warp, Codex, and Claude Code running. Never wrap the terminal or an agent session in Resource Guard.
- RAM relief is user-controlled: Resource Guard lists other apps the user can choose to quit. Do not automatically quit other apps to free RAM. CPU priority is a separate setting and does not reserve memory.
- Run resource-heavy local builds, broad tests, and browser automation through `"$HOME/.local/bin/resource-guard" run -- <command> <arguments>`. All projects share a maximum of two guarded jobs; memory pressure, swap activity, and CPU saturation can delay new starts.
- For a shell pipeline, wrap the whole pipeline with `resource-guard run -- /bin/zsh -c '...'`; preserve proper shell quoting. Do not start detached processes inside a guarded command. Long-running development servers stay outside the queue: reuse existing servers and avoid duplicates.
- Keep test/build workers at two or fewer when supported. The launcher does not rewrite tool-specific worker flags.
- If a job waits, let it wait and continue independent lightweight work using the agent's background tool execution when available. Never bypass the guard because it is waiting or unavailable. Report installation/monitoring errors instead.
- Use `"$HOME/.local/bin/resource-guard" status --json` for queue and resource status. Reading files, editing, targeted searches, and network reasoning do not need the launcher.
- Cancel only a specific task-owned guarded job when needed; never kill Warp, agent sessions, another session's jobs, or shared services. The user can cancel guarded jobs through Raycast Resource Guard.
- These instructions coordinate cooperating commands; they are not a hard RAM limit. Do not claim that RSS totals equal physical memory footprint.
