# Codex Adapter (M3) — Live Sessions + Notch Logo — Design

_2026-07-19. Branch `feat/agent-island-m1-m4`. Implements backlog item 1 from STATUS.md._

## Goal

Codex sessions appear in the notch panel alongside Claude sessions — live
activity titles, working/complete/error states, cwd/project context, active
counts — and the notch wing animates an OpenAI logo while Codex works (both
sprites side by side when both agents are active). Fully local, read-only,
zero Codex configuration, zero risk to the Codex session itself.

## Approach: read-only rollout tailer (chosen)

Codex appends every observation to `$CODEX_HOME/sessions/YYYY/MM/DD/
rollout-*.jsonl` as it works (`{timestamp, type, payload}` JSONL). The daemon
tails these files and maps entries onto the existing canonical `EventInput`
vocabulary — the same pipeline Claude hooks feed (`hub.ingest` → session
registry → WS snapshot → notch).

Alternatives rejected:

- **`notify` forwarder** (config.toml `notify = [...]`): requires mutating the
  user's Codex config (TOML top-level key ordering is fragile), only fires on
  turn boundaries (no live tool activity), and a broken forwarder can spam
  Codex's stderr. The tailer is strictly read-only — Codex cannot be disrupted.
- **chokidar/FSEvents watching**: native watcher edge cases in the packaged
  daemon and flaky tests. Plain `fs.stat` polling (1.5s on attached files, 10s
  rescans for new files) is deterministic, testable with tiny intervals, and
  negligible load (~130 files today). chokidar stays unused.

## Components (mirrors `adapters/claude`)

### `adapters/codex/event-mapper.ts` — pure, unit-tested

`CodexSessionContext` `{sessionId, cwd, lastCallTitles}` accumulates identity
from `session_meta` (session_id, cwd, originator, cli_version) and
`turn_context` (cwd, model, approval_policy — forwarded as `detail._meta` so
the existing row context UI shows `codex · on-request`).

`mapCodexEntry(entry, ctx): EventInput | null` — rollout entry → canonical
event. Verified against all 130 rollouts on this Mac:

| rollout entry | canonical event | title |
| --- | --- | --- |
| `session_meta` | `session_started` | `session started` |
| `event_msg/task_started` | `task_progress` | `working…` |
| `event_msg/task_complete` | `session_ended` | truncated `last_agent_message` or `finished responding` |
| `event_msg/turn_aborted` | `notification` (no action) | `turn interrupted` → idle |
| `event_msg/error`, `stream_error` (defensive) | `error` | message |
| `response_item/function_call` `exec_command` | `tool_use` | `Running <cmd>` |
| `response_item/function_call` `update_plan` | `tool_use` | `Updating the plan` |
| `response_item/function_call` `request_user_input` | `notification` (requires action) | `Codex asks a question` + pending_question |
| `response_item/custom_tool_call` `apply_patch` | `tool_use` | `Editing <file>` (first file in patch) |
| `event_msg/exec_command_end` | `task_progress` | `Reading <name>` / `Searching` / `working…` via `parsed_cmd` |
| `event_msg/patch_apply_end` | `task_progress` | `Edited N file(s)` |
| `event_msg/mcp_tool_call_end` | `task_progress` | `server.tool` |
| `event_msg/web_search_end` | `task_progress` | `Searching the web` |
| everything else (`token_count`, `agent_message`, `reasoning`, outputs…) | `null` (ignored) | |

`request_user_input` arguments carry `questions[{question, options[{label}]}]`
— same shape as Claude's AskUserQuestion, so `extractCodexQuestion` feeds the
existing "asks a question" card. Any later mapped event clears it (same
convention as the Claude route). Detail payloads stay compact: no stdout/
stderr/diff bodies, titles truncated like the Claude mapper.

### `adapters/codex/rollout-reader.ts` — the tailer

`CodexRolloutReader(codexHome, sink, opts)` where `sink = {ingest,
setPendingQuestion}` (EventHub-backed in main.ts, fake in tests). Behavior:

- **Rescan** every `scanMs`: walk `sessions/`, attach any rollout file with
  `mtime` within `activeMs` (stale files ignored until they change size on a
  later rescan).
- **Catch-up** on attach: parse the whole file once, feed every entry through
  the context tracker, but ingest only a compact summary — `session_started` +
  the last mapped event — so a 5,000-line historic session doesn't replay a
  firehose into the ring buffer. Then remember `offset = size`.
- **Poll** attached files every `pollMs`: if size grew, read only the appended
  bytes, buffer a trailing partial line, map + ingest each complete line.
- **Failure = silence + log**: unreadable file, malformed line, unknown entry
  — skip and keep going. `start()` is wrapped in main.ts so the daemon boots
  even if the reader cannot. Reading can never affect Codex.

### Notch UI (`packages/app`)

- `OpenAiSprite.tsx`: the OpenAI blossom mark (official petal geometry, 6
  rotations, `fill="currentColor"`), 13px, `role="img"` + aria-label. `live`
  adds a slow rotation (`prefers-reduced-motion` disables it, same block as
  the crab).
- `App.tsx` wing logic: crab shows when Claude sessions exist (or none of
  either — preserving today's bare look); OpenAI mark shows when Codex
  sessions exist; both when both → `island.dual` widens the collapsed island
  248→276px so both fit the wing beside the hardware notch.
- Everything else (rows, counts, states, colors, sounds, jump) is untouched —
  Codex rides the same `SessionSnapshot` stream; `agent-kind` already includes
  `"codex"` and SessionRow already labels it.

## Testing

- `event-mapper.test.ts`: table-driven mapping (all rows above), context
  accumulation, truncation, malformed/unknown entries → null, question
  extraction.
- `rollout-reader.test.ts`: tmp-dir fixtures with millisecond intervals —
  catch-up compaction, live append streaming, partial-line buffering,
  malformed lines skipped, new file pickup, stale files ignored, question
  set/clear.
- `pnpm typecheck` across the workspace; manual smoke against the 130 real
  rollouts (replay newest into a fake sink) and a live daemon run.
