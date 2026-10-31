# Contributing to Agent Island

Thanks for helping. Bug reports, ideas and pull requests are all welcome. For
questions, use [Discussions](https://github.com/soummyaanon/DEV-island/discussions);
for bugs and feature requests, open an [issue](https://github.com/soummyaanon/DEV-island/issues/new/choose).

## Build and run

The app is a Swift package in `apps/mac`. It builds with the Xcode Command
Line Tools alone (no Xcode project, no signing setup needed).

```sh
cd apps/mac
./scripts/test.sh                 # Swift Testing suites (IslandCore)
./scripts/bundle.sh debug --open  # build build/Agent Island Next.app and launch it
```

The debug build runs as **Agent Island Next** (`com.agentisland.app.next`)
beside an installed copy; quit the installed one to see yours. Logs:

```sh
/usr/bin/log show --last 5m --predicate 'subsystem == "com.agentisland.app.next"'
```

A debug build also plays moments on demand (see `apps/mac/README.md`): the
charger moment, a million-token confetti burst, and an Ask question, each from
a distributed notification. `AgentIsland --render-preview <folder>` draws every
page to PNGs.

## Layout

| Path | What lives there |
| --- | --- |
| `apps/mac/Sources/IslandCore` | Pure logic, no AppKit: sessions, the wings' rules, placement, settings, the daemon's core and the agent adapters. Everything here is tested. |
| `apps/mac/Sources/AgentIsland` | The app: the panel and pointer tracking (`IslandController`), the `@Observable` model, SwiftUI views, services. |
| `apps/mac/Sources/AgentIsland/Daemon` | The local HTTP server on `127.0.0.1:7433` and its routes. |
| `apps/mac/Tests/IslandCoreTests` | Swift Testing suites. |
| `packages/` | The 1.x Electron app and its TypeScript daemon, kept for reference. |
| `docs/superpowers` | Design specs and plans behind past features. |

## Adding an agent

Agents are adapters that turn an agent's own signals into the daemon's
canonical events (`EventInput` in `IslandCore/Daemon/DaemonCore.swift`):
`session_started`, `tool_use`, `task_progress`, `permission_request`,
`notification`, `session_ended`, `error`.

- Hook-based agents (like Claude Code and Cursor) get a route in
  `AgentIsland/Daemon/Daemon.swift` and a pure mapper in
  `IslandCore/Daemon/Adapters.swift`.
- Log-based agents (like Codex) get a tailer, as in
  `IslandCore/Daemon/CodexAdapter.swift`.
- Add the agent to `AgentKind`, give it a bot look and colour, and cover the
  mapper with tests.

You can try any agent without writing an adapter: `POST /events` with a
canonical event (see `DaemonCore.swift`) shows up on the island right away.

## Pull requests

- Keep each PR to one change, and describe what it does and why. For anything
  visual, include a screenshot or short recording.
- Put logic in `IslandCore` where it can be tested, and add tests for it.
  `./scripts/test.sh` must pass; CI runs it on macOS 26.
- Match the surrounding code: its naming, comment density and idiom. Views hold
  no `@State` (SwiftUI's macros need Xcode's plugin); state lives in
  `@Observable` models.
- Respect the house rules: small, quiet UI; motion that feels native; nothing
  that samples while the island is closed; Reduce Motion, Increase Contrast and
  Reduce Transparency followed.
- Never add network calls or telemetry. Anything that leaves the Mac must be
  opt-in and listed in the README's Privacy section.
- Commit subjects are short sentences describing the change
  ("Side island: thinking orbs and a clock"), with detail in the body.

By contributing, you agree that your contributions are licensed under the
[MIT License](LICENSE).
