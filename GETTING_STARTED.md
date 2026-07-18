# Agent Island — Getting Started

**Scope for v0.1 (MVP):** integrate exactly two agents — **Claude Code** and **Codex CLI** — and surface their sessions in a native macOS menu bar / Dynamic Island app. Everything else (Gemini, Cursor, orchestration, task-splitting) is explicitly out of scope for now.

---

## 1. What you're building (MVP definition)

A three-part system:

```
┌─────────────────┐     ┌──────────────────┐     ┌──────────────────────┐
│  Claude Code     │     │                  │     │  Agent Island.app     │
│  (hooks → HTTP)  │────▶│  agentislandd    │────▶│  (Electron menu bar   │
├─────────────────┤     │  local daemon    │ WS  │   + Dynamic Island)   │
│  Codex CLI       │────▶│  (event hub)     │     │                      │
│  (notify + logs) │     │  localhost:7433  │     └──────────────────────┘
└─────────────────┘     └──────────────────┘
```

1. **`agentislandd`** — a small local Node.js daemon (plain Node process, no Electron dependency) that listens on `localhost` (e.g. port `7433`), receives events from adapters, normalizes them into one event schema, and streams them to the UI over a WebSocket or Unix domain socket.
2. **Two adapters** — thin integration layers, one per agent. Neither agent needs to be modified; both expose enough surface area (hooks, notify commands, session logs) to observe them from the outside.
3. **The Electron app** — menu bar + notch-overlay app showing live sessions, statuses, and permission requests, with click-through back to the originating terminal.

**MVP success criteria:** you can run a Claude Code session and a Codex session in two terminals, see both appear in the menu bar with live status ("working", "waiting for approval", "done"), get a notification when either finishes, and see permission requests from Claude Code inline.

---

## 2. Prerequisites

- macOS 14+ (Dynamic Island UI requires a notch/Island-capable Mac or a simulated notch window; menu bar works everywhere)
- Node.js 20+ and pnpm 9+ (Electron, TypeScript, electron-vite, electron-builder)
- Claude Code installed (`npm install -g @anthropic-ai/claude-code`) — docs: https://docs.claude.com/en/docs/claude-code/overview
- Codex CLI installed (`npm install -g @openai/codex` or `brew install codex`) — docs: https://developers.openai.com/codex
- Comfortable reading NDJSON (newline-delimited JSON) — both agents speak it

---

## 3. Suggested build order (4 milestones)

### Milestone 1 — The daemon and event schema (1 week)

Before touching any agent, define your canonical event. Everything in Agent Island is one of these:

```json
{
  "id": "uuid",
  "agent": "claude-code" | "codex",
  "session_id": "string",
  "cwd": "/path/to/project",
  "timestamp": "ISO-8601",
  "type": "session_started" | "task_progress" | "tool_use" |
          "permission_request" | "notification" | "session_ended" | "error",
  "title": "short human-readable line",
  "detail": {},
  "requires_action": false
}
```

Build `agentislandd` with:
- An HTTP endpoint `POST /events` (adapters push events here)
- A WebSocket endpoint `GET /stream` (the UI subscribes here)
- An in-memory session registry keyed by `(agent, session_id)` so the UI can show *current state*, not just a firehose of events
- Launch via a `launchd` agent plist so it starts at login

Test it with `curl` before writing any adapter.

### Milestone 2 — Claude Code adapter (1 week)

Claude Code is the easier of the two because **hooks are a first-class feature** — you don't need to parse logs at all.

**Approach: HTTP hooks pointed at your daemon.** Claude Code hooks are user-defined commands or HTTP endpoints that fire automatically at lifecycle points (session start, before/after every tool call, when a notification fires, when the session stops). HTTP hooks POST the event's JSON input directly to a URL with `Content-Type: application/json` — which means your daemon can receive Claude Code events with **zero shell scripts**.

In `~/.claude/settings.json`, register hooks for the events you care about:

```json
{
  "hooks": {
    "SessionStart": [
      { "hooks": [ { "type": "http", "url": "http://localhost:7433/events/claude/session-start", "timeout": 5 } ] }
    ],
    "PreToolUse": [
      { "matcher": "*", "hooks": [ { "type": "http", "url": "http://localhost:7433/events/claude/pre-tool", "timeout": 5 } ] }
    ],
    "PostToolUse": [
      { "matcher": "*", "hooks": [ { "type": "http", "url": "http://localhost:7433/events/claude/post-tool", "timeout": 5 } ] }
    ],
    "Notification": [
      { "hooks": [ { "type": "http", "url": "http://localhost:7433/events/claude/notification", "timeout": 5 } ] }
    ],
    "Stop": [
      { "hooks": [ { "type": "http", "url": "http://localhost:7433/events/claude/stop", "timeout": 5 } ] }
    ]
  }
}
```

Key facts to design around:
- Every hook payload includes a `hook_event_name` field plus common fields (session id, cwd, transcript path) and event-specific fields — your adapter maps these onto the canonical schema.
- **Permission approvals:** `PreToolUse` hooks can return a JSON decision that allows or blocks a tool call. For the MVP, treat `Notification` events (which fire when Claude is waiting for permission or idle) as your "needs attention" signal and deep-link the user back to the terminal. A later version can implement real remote-approve by returning decisions from an HTTP hook — but that means your daemon must answer synchronously while the user taps a button, so keep it out of v0.1.
- **Config snapshotting:** Claude Code snapshots hook config at session start; edits to settings don't hot-apply to running sessions. Document this in your onboarding ("restart your Claude session after installing Agent Island").
- **Timeouts:** for HTTP hooks, non-2xx responses and timeouts are non-blocking — a dead daemon won't break the user's Claude session. This is exactly the failure mode you want; keep hook timeouts short (5s).

Verify against the official hooks reference before hardcoding any schema: https://code.claude.com/docs/en/hooks

### Milestone 3 — Codex adapter (1–1.5 weeks)

Codex has no hooks system equivalent, so the adapter combines two mechanisms:

**a) `notify` for completion/attention events.** Codex's `~/.codex/config.toml` supports a `notify` setting — an external program Codex invokes with a JSON payload when a turn completes or approval is needed. Point it at a tiny script that forwards the payload to your daemon:

```toml
# ~/.codex/config.toml
notify = ["/usr/local/bin/agent-island-notify"]
```

```bash
#!/bin/bash
# /usr/local/bin/agent-island-notify — Codex passes the JSON payload as $1
curl -s -m 3 -X POST http://localhost:7433/events/codex/notify \
  -H "Content-Type: application/json" -d "$1" || true
```

**b) Session log tailing for live progress.** Codex automatically writes per-session JSONL rollout logs under `$CODEX_HOME/sessions/YYYY/MM/DD/rollout-*.jsonl` (default `CODEX_HOME` is `~/.codex`). Your adapter:
1. Watches the sessions directory with FSEvents (or `DispatchSource` on the fd)
2. Tails new/growing `rollout-*.jsonl` files line by line
3. Maps entries (user turns, tool calls, command executions, completions) onto the canonical schema

This gives you real-time "what is Codex doing right now" without Codex knowing Agent Island exists. Verify the current rollout format against the version you install — the field names have shifted across releases, so parse defensively and log unknown entry types instead of crashing.

**c) (Optional, later) `codex exec --json`.** For non-interactive runs, `codex exec` supports a `--json` flag that emits structured events on stdout. Useful if Agent Island later *launches* Codex tasks itself, but unnecessary for the MVP, which only observes sessions the user starts.

Codex docs: https://developers.openai.com/codex

### Milestone 4 — The Electron app (1.5–2 weeks)

- **Menu bar:** Electron's `Tray` API (`new Tray(icon)` + a positioned frameless `BrowserWindow` that opens under the tray icon — the classic "menubar app" pattern; the `menubar` npm package wraps exactly this). Show a compact list: agent icon, project name (from `cwd`), status dot, elapsed time. Use a **template image** for the tray icon so it adapts to light/dark menu bars.
- **Dynamic Island / notch UI:** a second `BrowserWindow` that is frameless, `transparent: true`, `alwaysOnTop: true` (level `'screen-saver'`), `focusable: false`, with `setVisibleOnAllWorkspaces(true)` — positioned over the notch using `screen.getPrimaryDisplay()` geometry. Use `setIgnoreMouseEvents(true, { forward: true })` when collapsed so it doesn't steal clicks, and toggle it off when expanded. Animate collapse/expand in CSS.
- **Notifications:** Electron's `Notification` API (uses native macOS notifications). Click handler deep-links to the session.
- **Jump-to-terminal:** shell out to AppleScript via `child_process` (`osascript`) — Terminal.app and iTerm2 are scriptable; for other terminals fall back to activating the app by bundle id (`open -b`). Use the session's `cwd` to disambiguate windows where possible.
- **Connection to daemon:** run the daemon as a separate Node process (forked by the app, or launchd-managed) and subscribe from the **main process** over WebSocket; forward state to renderer windows via IPC (`ipcMain`/`ipcRenderer` with a `contextBridge` preload). Fetch `GET /sessions` on launch/reconnect so the UI is correct even if it starts after sessions began.
- **App hygiene:** hide the Dock icon (`app.dock.hide()`), launch at login via `app.setLoginItemSettings`, and single-instance-lock so two copies never run.

---

## 4. Full code file structure (Electron + TypeScript)

One pnpm monorepo, TypeScript end-to-end. The daemon and the Electron app share event types through a plain workspace package — same "single source of truth" idea, no Swift needed.

```
agent-island/
├── README.md
├── package.json                              # workspace root
├── pnpm-workspace.yaml                       # packages: shared, daemon, app
├── tsconfig.base.json
├── .github/workflows/ci.yml                  # lint + typecheck + tests
│
├── packages/shared/                          # @agent-island/shared — used by daemon AND app
│   ├── package.json
│   └── src/
│       ├── agent-event.ts                    # AgentEvent interface + zod schema — single source of truth
│       ├── agent-kind.ts                     # 'claude-code' | 'codex'
│       ├── session-state.ts                  # 'starting'|'working'|'waiting-for-approval'|'idle'|'done'|'failed'
│       ├── session-snapshot.ts               # current state of one session (what the UI renders)
│       ├── wire-protocol.ts                  # WS envelopes: {type:'event'|'snapshot'|'ping', ...}
│       └── index.ts
│
├── packages/daemon/                          # agentislandd — plain Node process (no Electron dep)
│   ├── package.json                          # deps: @agent-island/shared, fastify, @fastify/websocket, chokidar, zod
│   └── src/
│       ├── main.ts                           # arg parsing, wiring, graceful shutdown
│       ├── config.ts                         # port (7433), token path, CODEX_HOME resolution
│       ├── auth-token.ts                     # generate/read ~/.agent-island/token, header check middleware
│       │
│       ├── hub/
│       │   ├── event-hub.ts                  # ingest → registry update → fanout to WS subscribers
│       │   ├── session-registry.ts           # Map<`${agent}:${sessionId}`, SessionSnapshot> + state machine
│       │   └── event-log.ts                  # ring buffer of recent events for GET /events + debug
│       │
│       ├── server/
│       │   ├── http-server.ts                # fastify instance, binds 127.0.0.1 ONLY
│       │   ├── routes-claude.ts              # POST /events/claude/:hookEvent (session-start, pre-tool, post-tool, notification, stop)
│       │   ├── routes-codex.ts               # POST /events/codex/notify
│       │   ├── routes-ui.ts                  # GET /sessions (snapshot), GET /health
│       │   └── ws-stream.ts                  # GET /stream — subscriber set, heartbeat, backpressure
│       │
│       ├── adapters/claude/
│       │   ├── hook-payload.ts               # zod schemas for hook JSON (hook_event_name, session_id, cwd, tool_name…)
│       │   └── event-mapper.ts               # pure fn: hook payload → AgentEvent[] (+ state hints)
│       │
│       └── adapters/codex/
│           ├── notify-payload.ts             # zod schema for the notify JSON payload
│           ├── event-mapper.ts               # pure fn: notify/rollout entries → AgentEvent[]
│           ├── sessions-watcher.ts           # chokidar on $CODEX_HOME/sessions/** — detects new rollout files
│           ├── rollout-tailer.ts             # per-file: tail growing .jsonl, line-buffered NDJSON parse
│           └── rollout-entry.ts              # tolerant decoder — unknown entry types counted, never fatal
│
├── packages/daemon/test/
│   ├── claude-mapper.test.ts                 # fixture hook payloads → expected events (vitest)
│   ├── codex-rollout.test.ts                 # fixture rollout lines (incl. malformed/unknown)
│   ├── session-registry.test.ts              # state machine transitions
│   └── fixtures/
│       ├── claude/                           # captured real hook payloads, one .json per event type
│       └── codex/                            # captured rollout-*.jsonl samples
│
├── packages/app/                             # Agent Island.app (Electron)
│   ├── package.json                          # deps: electron, electron-builder, @agent-island/shared
│   ├── electron-builder.yml                  # mac target, LSUIElement: true (no Dock icon), notarization
│   ├── vite.config.ts                        # electron-vite: main / preload / renderer builds
│   │
│   ├── src/main/                             # ── Electron MAIN process ──
│   │   ├── index.ts                          # app lifecycle, single-instance lock, app.dock.hide()
│   │   ├── daemon-manager.ts                 # spawn/monitor daemon child process (or defer to launchd)
│   │   ├── daemon-client.ts                  # WS client to /stream, auto-reconnect w/ backoff, GET /sessions on connect
│   │   ├── app-state.ts                      # authoritative UI state in main; broadcast to windows via IPC
│   │   ├── tray.ts                           # Tray icon (template image), attention badge, click → toggle popover
│   │   ├── windows/
│   │   │   ├── popover-window.ts             # frameless BrowserWindow positioned under tray icon
│   │   │   └── notch-window.ts               # transparent, alwaysOnTop, focusable:false, ignoreMouseEvents when collapsed
│   │   ├── notifications.ts                  # Electron Notification: finished / needs-attention, click → focus session
│   │   ├── jump-back.ts                      # osascript for Terminal/iTerm2, `open -b` fallback, cwd disambiguation
│   │   └── auto-launch.ts                    # app.setLoginItemSettings, first-run onboarding trigger
│   │
│   ├── src/preload/
│   │   └── index.ts                          # contextBridge: expose typed `window.agentIsland` API, nothing else
│   │
│   └── src/renderer/                         # ── UI (React or plain TS + Vite) ──
│       ├── index.html
│       ├── main.tsx
│       ├── ipc.ts                            # typed wrappers over window.agentIsland
│       ├── popover/
│       │   ├── SessionList.tsx               # rows of sessions
│       │   ├── SessionRow.tsx                # agent icon, project name, status dot, elapsed time
│       │   └── SessionDetail.tsx             # recent events for one session
│       ├── notch/
│       │   ├── NotchCompact.tsx              # collapsed: dots per active agent
│       │   └── NotchExpanded.tsx             # expanded: current task line + approve-pending badge
│       └── styles/
│           └── island.css                    # collapse/expand animations, vibrancy-ish styling
│
├── installers/
│   ├── install.sh                            # one-shot: daemon → launchd → hooks → notify script
│   ├── claude-hooks.json                     # hook template merged into ~/.claude/settings.json
│   ├── merge-claude-settings.js              # safe JSON merge (never clobber user's existing hooks)
│   ├── agent-island-notify.sh                # Codex notify forwarder → POST /events/codex/notify
│   ├── codex-config-patch.md                 # instructions for the notify line in ~/.codex/config.toml
│   ├── com.agentisland.daemon.plist          # launchd agent (KeepAlive, RunAtLoad) — if not app-spawned
│   └── uninstall.sh                          # remove hooks, notify script, launchd job
│
└── docs/
    ├── architecture.md                       # the diagram from §1, expanded
    ├── event-schema.md                       # canonical schema + per-agent mapping tables
    └── adding-an-adapter.md                  # write this in v0.2 when you add agent #3
```

**Why this shape:**

- **`packages/shared` with zod schemas** is the most important decision — the daemon *validates* incoming payloads and the app *trusts* decoded types, all from one definition. The wire protocol can't drift between the two halves, and zod gives you runtime validation for free at the daemon's edges.
- **The daemon has no Electron dependency.** It's a plain Node process, so it can run under launchd without the app open, be tested with vitest in CI, and later be swapped or rewritten (Go, Rust) without touching the UI.
- **Mappers are pure functions** with fixture-based tests. When Claude Code or Codex changes their format, you capture one new fixture file, fix one mapper, and everything downstream is untouched.
- **`session-registry.ts` owns all state transitions** (e.g. `PreToolUse` → `working`, `Notification` → `waiting-for-approval`, `Stop` → `done`). Adapters only translate; they never decide state. That keeps the two agents' quirks from leaking into the UI.
- **All daemon I/O lives in the main process, never the renderer.** Renderers get state via IPC through a locked-down `contextBridge` preload (`contextIsolation: true`, `nodeIntegration: false`). This is both Electron security hygiene and what keeps the popover and notch windows trivially in sync — they render the same broadcast state.
- **`installers/` is a first-class citizen** because your product's onboarding *is* config editing in two other tools' dotfiles. The merge script matters: blindly overwriting `~/.claude/settings.json` and destroying a user's existing hooks is the fastest way to lose a developer's trust.

**Dev loop:** `pnpm dev` runs the daemon with `tsx watch` + the app via electron-vite HMR. Renderer changes hot-reload; daemon restarts are invisible to running agents (hooks just retry on the next event).
---

## 5. Gotchas to plan for early

1. **Don't parse what you can subscribe to.** Claude Code = hooks (structured, supported). Codex = notify + session logs. Resist the temptation to scrape terminal output — it breaks on every UI change.
2. **Multiple concurrent sessions per agent** is the whole point of the product. Key everything by `session_id` from day one; never assume one session per agent.
3. **Daemon absence must be harmless.** Both integrations should silently no-op if the daemon is down (short timeouts, `|| true`). A monitoring tool that breaks the tools it monitors is dead on arrival.
4. **Schema drift.** Both CLIs ship weekly. Version-tag your adapters, parse defensively, and surface "unknown event" counts in a debug view instead of crashing.
5. **Security.** Bind the daemon to `127.0.0.1` only, and add a simple shared token (written to `~/.agent-island/token`, sent as a header) so other local processes can't spoof agent events or, later, approvals.
6. **Approvals are v0.2, not v0.1.** Remote-approving a Claude Code tool call means holding a synchronous hook request open while a human taps a button. Get read-only monitoring rock-solid first.

---

## 6. First working session — checklist

- [ ] `agentislandd` runs, `curl -X POST localhost:7433/events` shows up in `GET /stream`
- [ ] Claude Code hooks installed; starting `claude` in any repo produces `session_started` in the daemon
- [ ] A tool call in Claude Code produces `tool_use` events with the tool name
- [ ] Codex `notify` script installed; finishing a Codex turn produces a `notification` event
- [ ] Codex rollout tailer emits `task_progress` events during a live session
- [ ] Menu bar app shows both sessions with correct status and clears them on `session_ended`
- [ ] macOS notification fires when either agent stops

Ship that, then iterate toward approvals and the Dynamic Island polish.

---

## 7. Reference links

- Claude Code overview: https://docs.claude.com/en/docs/claude-code/overview
- Claude Code hooks reference: https://code.claude.com/docs/en/hooks
- Codex CLI docs (incl. non-interactive mode & config): https://developers.openai.com/codex
- `menubar` npm package (tray + popover window pattern): https://www.npmjs.com/package/menubar
- Electron docs (Tray, BrowserWindow, Notification): https://www.electronjs.org/docs/latest
