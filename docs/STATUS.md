# Agent Island — Session Memory / Resume Notes

_Last updated: 2026-07-19 (afternoon session). Branch: `feat/agent-island-m1-m4`._

## What exists and WORKS (all committed)

- **Daemon** (`packages/daemon`, self-contained `dist/main.cjs`): POST /events,
  Claude hook routes, held approvals (POST /approvals/:id), pending questions,
  WS /stream, /sessions, /events, /usage, /health. Token auth (lenient dev /
  strict prod). Codex usage reader (local rollout `rate_limits`, 10-min
  recency gate).
- **Claude adapter**: all 6 hooks via HTTP (SessionStart/Pre/PostToolUse/
  PermissionRequest/Notification/Stop), terminal identity headers for jump,
  permission_mode + rich activity titles, AskUserQuestion -> pending_question.
- **Codex adapter (M3) — DONE**: read-only rollout tailer in the daemon
  (`adapters/codex/rollout-reader.ts` + pure `event-mapper.ts`, 31 vitest
  tests — the repo's first). Stat-polls `$CODEX_HOME/sessions` (1.5s/10s),
  compact catch-up (session_started + latest state), live tool titles
  ("Running…", "Editing…"), task_started/complete/aborted lifecycle,
  request_user_input -> pending_question card, model+approval_policy in
  meta. Zero Codex config, never writes to Codex, failures = log lines.
  Design: docs/superpowers/specs/2026-07-19-codex-adapter-design.md.
- **Notch dual sprites**: OpenAI blossom (official petal path, currentColor,
  slow spin when live, reduced-motion aware) for Codex; crab for Claude;
  both side by side when both agents run (island 248->276px "dual" mode).
- **Quit crash FIXED**: "Object has been destroyed" on quit (late ws close ->
  emit -> send to destroyed window). DaemonClient suppresses emits after
  stop(); every webContents.send site guarded with isDestroyed().
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

1. **Stability + size reduction** (user's stated goal 2026-07-19): shrink
   DMG/app further. Done so far: en-only electronLanguages, react/react-dom
   out of the packed asar (renderer is vite-bundled), old release/ artifacts
   cleaned (357MB). Remaining ideas: prune asar further, single target
   (drop zip if unused), Electron upgrade, asar unpack audit.
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
