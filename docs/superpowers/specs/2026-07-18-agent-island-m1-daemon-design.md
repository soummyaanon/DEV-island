# Agent Island — Milestone 1 Design: Daemon + Event Schema

**Date:** 2026-07-18
**Status:** Approved
**Scope:** First build slice of Agent Island v0.1. Everything downstream (Claude adapter, Codex adapter, Electron app) depends on this.

---

## Goal

Build the shared event contract (`@agent-island/shared`) and the local daemon (`agentislandd`) so that a canonical `AgentEvent` can be POSTed over HTTP, normalized, folded into per-session state, and streamed live to subscribers over WebSocket. Provable end-to-end with `curl`.

**Success criteria (from GETTING_STARTED.md §6):**
`curl -X POST localhost:7433/events` with a sample event → appears on a `GET /stream` WS client and in `GET /sessions` with the correct derived `state`; `GET /health` returns ok.

**Out of scope for M1:** agent-specific ingest routes + mappers (`/events/claude/...`, `/events/codex/notify`), the Electron app, remote approvals. Automated test suite is deferred (state machine kept as a pure function so tests drop in later).

---

## Section A — `@agent-island/shared` (the contract)

Every type below is a zod schema with an inferred TS type exported. The daemon validates at its edges; the app trusts the decoded types.

```
AgentKind    = 'claude-code' | 'codex'
EventType    = 'session_started' | 'task_progress' | 'tool_use'
             | 'permission_request' | 'notification' | 'session_ended' | 'error'
SessionState = 'starting' | 'working' | 'waiting-for-approval' | 'idle' | 'done' | 'failed'
```

**`EventInput`** — accepted by `POST /events` (adapters stay dumb):
`{ agent, session_id, cwd, type, title, detail?, requires_action? }`

**`AgentEvent`** — canonical event after the daemon **mints `id` (uuid via `crypto.randomUUID()`) + `timestamp` (ISO-8601)** and applies defaults (`detail: {}`, `requires_action: false`). Decision: daemon-minted ids/timestamps rather than trusting the sender, so future adapters stay trivial.

**`SessionSnapshot`** — derived state the UI renders:
`key` (`${agent}:${session_id}`), `agent`, `session_id`, `cwd`, `state`, `title` (latest activity line), `requires_action`, `started_at`, `updated_at`, `last_event_type`, `event_count`.

**Wire protocol** (WS envelopes, discriminated union on `type`):
- `{ type: 'snapshot', sessions: SessionSnapshot[] }` — sent once on connect
- `{ type: 'event', event: AgentEvent, session: SessionSnapshot }` — per ingested event
- `{ type: 'ping', t: string }` — heartbeat

---

## Section B — `agentislandd` (the daemon)

M1 file layout (subset of the guide's tree):

```
packages/daemon/src/
├── main.ts          # arg parse, wiring, graceful shutdown (SIGINT/SIGTERM)
├── config.ts        # host 127.0.0.1, port 7433, token path, env overrides
├── auth-token.ts    # ensure ~/.agent-island/token; verify header
├── hub/
│   ├── event-hub.ts        # ingest(EventInput) → normalize → registry.apply → fan out
│   ├── session-registry.ts # Map<key, SessionSnapshot> + pure state machine
│   └── event-log.ts        # ring buffer (last 500 events)
└── server/
    ├── http-server.ts      # Fastify, binds 127.0.0.1 ONLY
    ├── routes-ingest.ts    # POST /events  (generic canonical ingest)
    ├── routes-ui.ts        # GET /sessions, GET /events, GET /health
    └── ws-stream.ts        # GET /stream — subscriber set + 30s heartbeat
```

**State machine** — pure function `applyEvent(state, type, requires_action) → SessionState`:
- `session_started` → `starting`
- `task_progress` / `tool_use` → `working`
- `permission_request` → `waiting-for-approval`
- `notification` → `waiting-for-approval` if `requires_action` else `idle`
- `session_ended` → `done`
- `error` → `failed`

Adapters only translate to canonical events; the registry alone decides state.

**Auth:** daemon creates `~/.agent-island/token` (random hex) on first run and logs it. `POST /events` checks a bearer / `X-Agent-Island-Token` header. Default **lenient in dev** (missing token → warn + allow, so `curl` stays a one-liner); **strict when `NODE_ENV=production`** or `AGENT_ISLAND_STRICT=1`.

**Fan-out:** event-hub keeps the WS subscriber set. On ingest: validate → normalize → `registry.apply` → push `{type:'event', event, session}` to all subscribers and append to the ring buffer. New WS connections first receive `{type:'snapshot', sessions}`.

---

## Section C — launchd + a real build

The daemon `build` script becomes **esbuild → `dist/main.js`** (single bundled file) so launchd has a stable entrypoint. Day-to-day dev still uses `pnpm dev` (`tsx watch`).

- `installers/com.agentisland.daemon.plist` — `RunAtLoad` + `KeepAlive`, runs `node <abs>/dist/main.js`
- `installers/install-daemon.sh` — build, template absolute paths into the plist, `launchctl load`
- `installers/uninstall-daemon.sh` — `launchctl unload` + remove plist

---

## Section D — Verification (manual, no automated suite)

`scripts/smoke.sh` (or documented curl commands) runs the §6 checklist in one shot:
1. `GET /health` → 200 ok
2. `POST /events` a sample `session_started` → 200, event echoed
3. background WS client on `/stream` receives the `event` envelope
4. `GET /sessions` shows the session with `state: working`/`starting`
5. `GET /events` shows the event in the ring buffer

---

## Rationale

- **`shared` with zod** is the single source of truth; the wire protocol can't drift between daemon and app, and the daemon gets runtime validation for free at its edges.
- **Daemon has no Electron dependency** — plain Node, runnable under launchd, swappable later.
- **State machine is a pure function** — trivial to unit-test when we add tests; adapters never decide state.
- **Daemon absence is harmless** — short hook timeouts on the adapter side (M2/M3); a dead daemon never breaks the monitored tools.
- **Security** — bind `127.0.0.1` only + shared token so other local processes can't spoof events.
