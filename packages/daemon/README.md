# agentislandd

Local event hub for Agent Island. Receives canonical `AgentEvent`s over HTTP,
folds them into per-session state, and streams them to the UI over WebSocket.
Binds to `127.0.0.1` only.

## Run

```bash
# dev (hot reload via tsx)
pnpm --filter @agent-island/daemon dev

# from the built bundle (what launchd runs)
pnpm --filter @agent-island/daemon build
pnpm --filter @agent-island/daemon start:dist
```

## HTTP / WS surface

| Method | Path                         | Purpose                                                       |
| ------ | ---------------------------- | ------------------------------------------------------------ |
| POST   | `/events`                    | Ingest one canonical event (`EventInput`); daemon mints id + timestamp |
| POST   | `/events/claude/:hookEvent`  | Claude Code HTTP-hook ingest (adapter); always replies empty `204` |
| GET    | `/stream`                    | WebSocket: `snapshot` on connect, then `event` + `ping`      |
| GET    | `/sessions`                  | Current `SessionSnapshot[]`                                  |
| GET    | `/events`                    | Recent events from the ring buffer (`?limit=N`)             |
| GET    | `/health`                    | Liveness + session/subscriber counts                        |

The Claude route accepts hook slugs `session-start`, `pre-tool`, `post-tool`,
`permission-request`, `notification`, `stop`. It returns an **empty 204** on
purpose: Claude parses any 2xx JSON body as a decision that could alter the live
session, so a monitoring endpoint must never send one.

`POST /events` example:

```bash
curl -X POST http://127.0.0.1:7433/events \
  -H 'content-type: application/json' \
  -d '{"agent":"claude-code","session_id":"abc","cwd":"/repo","type":"session_started","title":"hello"}'
```

## Config (env vars)

| Var                        | Default            | Notes                                      |
| -------------------------- | ------------------ | ------------------------------------------ |
| `AGENT_ISLAND_HOST`        | `127.0.0.1`        | Bind address (keep local)                  |
| `AGENT_ISLAND_PORT`        | `7433`             |                                            |
| `AGENT_ISLAND_HOME`        | `~/.agent-island`  | Token + logs live here                     |
| `AGENT_ISLAND_STRICT`      | off                | `1` rejects `POST /events` without a token |
| `NODE_ENV=production`      | —                  | Implies strict auth                        |
| `AGENT_ISLAND_RING_SIZE`   | `500`              | Ring buffer capacity                       |
| `AGENT_ISLAND_HEARTBEAT_MS`| `30000`            | WS ping interval                           |

## Auth

On first run the daemon writes a random token to `$AGENT_ISLAND_HOME/token`
(mode `0600`). In strict mode, `POST /events` requires it as
`Authorization: Bearer <token>` or `X-Agent-Island-Token: <token>`. GET routes
are open (localhost only). Dev mode logs a warning and accepts unauthenticated
posts so `curl` stays a one-liner.

## Install as a launchd agent (start at login)

```bash
./installers/install-daemon.sh     # build + register (runs in strict mode)
./installers/uninstall-daemon.sh   # remove
```

## Claude Code adapter (Milestone 2)

Register HTTP hooks in `~/.claude/settings.json` (safe, backed-up, idempotent
merge that never clobbers your existing config):

```bash
./installers/install-claude-hooks.sh              # add hooks (backs up first)
./installers/install-claude-hooks.sh --dry-run    # preview only
./installers/uninstall-claude-hooks.sh            # remove only our hooks
```

Hooks are snapshotted at session start, so restart `claude` to pick up changes.
If the daemon is down, hooks fail fast (connection refused) and never disrupt
the session.

## Verify

```bash
# with the daemon running:
pnpm smoke                     # generic pipeline
node scripts/claude-smoke.mjs  # Claude adapter mapping + states
node scripts/ws-tail.mjs       # live tail of the event stream
```
