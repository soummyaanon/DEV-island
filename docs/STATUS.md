# Agent Island — Session Memory / Resume Notes

_Last updated: 2026-07-19 (late night session). Branch: `feat/agent-island-m1-m4` (pushed)._

## What exists and WORKS (all committed)

- **Daemon** (`packages/daemon`, self-contained `dist/main.cjs`): POST /events,
  Claude hook routes, held approvals (POST /approvals/:id), pending questions,
  WS /stream, /sessions, /events, /usage, /health. Token auth (lenient dev /
  strict prod). Codex usage reader (local rollout `rate_limits`, 10-min
  recency gate).
- **Claude adapter**: all 6 hooks via HTTP (SessionStart/Pre/PostToolUse/
  PermissionRequest/Notification/Stop), terminal identity headers for jump,
  permission_mode + rich activity titles, AskUserQuestion -> pending_question.
- **Electron app** (`packages/app`): TRUE notch hug — `type:"panel"` +
  `enableLargerThanScreen:true` -> windowY=0 over the menu-bar band (the
  breakthrough; see skill below). Island wraps the notch, animated 2-frame
  crab + count in the wings, invisible ("bare") when no sessions, hover/
  attention auto-expand, approval diff panel with ⌘Y/⌘N, "Claude asks" card,
  jump-to-terminal (iTerm2 precise), 8-bit sounds (attention ping loud, tray
  toggle), Codex usage footer, Zero Config (auto-installs hooks on launch,
  safe merge + backup), auto-spawns daemon, Open-at-Login toggle, memory trim
  (~150MB floor accepted, HW accel off).
- **Packaging**: `pnpm package` -> scripts/package-dmg.sh -> builds, deep
  **ad-hoc signs** (unsigned = "damaged" on Apple Silicon!), makes DMG with
  "READ ME FIRST.txt" (Gatekeeper Open-Anyway steps inside).
  Artifact: `packages/app/release/Agent Island-0.1.0-arm64.dmg` (~114MB).

## Immediately pending (user side)

- Re-AirDrop the NEW DMG to the other Mac (old copy showed "damaged"; new one
  shows normal prompt -> Settings > Privacy & Security > Open Anyway).

## Next up (agreed backlog, in rough priority)

1. **Codex adapter (M3)** — notify forwarder + rollout tailer. Research DONE:
   rollout format mapped (`~/.codex/sessions/**/rollout-*.jsonl`, entries
   `{timestamp,type,payload}`; session_meta has session_id+cwd; event_msg
   task_started/task_complete; response_item tool calls). notify = argv[1]
   JSON, config.toml needs `notify = [...]` PREPENDED (top-level keys before
   tables). 128 real rollouts on this Mac to test against.
2. Homebrew cask (free no-warning distribution) — user deferred.
3. Apple Developer ID ($99) -> real signing + notarization + electron-updater
   auto-update (zip artifact + blockmaps already produced). 15-min job in
   package-dmg.sh once ID exists.
4. Claude usage tracking — NO local source found (policy-limits.json is not
   usage); needs research spike (transcript-based estimate or authed API).
5. More terminal jump precision (Terminal.app/Warp/WezTerm tabs).
6. SSH remote, "Ask" remote-answering (keystroke injection) — big/uncertain.

## Key knowledge (don't re-learn)

- **Notch skill**: `~/.claude/skills/electron-notch-overlay/SKILL.md` — the
  whole hug technique with measured evidence + sources. Auto-triggers.
- macOS clamps windows below menu bar UNLESS panel+enableLargerThanScreen.
  Never CSS-negative-margin (clips behind notch). Measure inset =
  workArea.y - getBounds().y at runtime (33 on this Mac).
- Notch width this Mac ≈ 196px logical. Menu bar 33px (scaled res).
- Claude hooks snapshot at session start -> restart claude sessions after
  hook changes. Empty 204 from claude routes is a SAFETY contract (2xx JSON
  = decision injection).
- Electron install had broken extraction once: fix = ditto -x -k the cached
  zip into dist (see git history if it recurs). pnpm reserves `pack` — use
  `pnpm run pack` / `pnpm package`.
- Single-instance lock: kill dev instances (`pkill -f electron@35.7.5`)
  before launching the packaged app; daemon port 7433.

## How to resume dev

```bash
pnpm --filter @agent-island/app dev     # or: open the installed app
node scripts/ws-tail.mjs                # live event stream
pnpm smoke && node scripts/claude-smoke.mjs   # daemon verifications
pnpm package                            # fresh signed DMG
```
