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
- **Cursor adapter — DONE (3-agent launch)**: Cursor hooks (~/.cursor/
  hooks.json, 12 events) -> fire-and-forget bridge script (~/.agent-island/
  bin/cursor-hook.sh, backgrounds curl so Cursor NEVER waits) -> POST
  /events/cursor/:hookEvent -> pure mapper (7 tests). Zero-config safe-merge
  preserves other tools' hook entries (vibe-island coexists). Jump on a
  cursor session activates Cursor.app. Cube sprite in the wing.
- **Notch auto-adapt**: JXA/NSScreen (auxiliaryTopLeftArea/RightArea) measures
  the REAL notch width at startup (185pt on this Mac) -> --notch-width CSS
  var drives all island widths. Works on Air 13" etc.; 196px fallback when
  no notch. spr-2/spr-3 classes widen the wings per sprite count.
- **Round-2 UX**: electric working feel (bottom scanline sweep, neon glow on
  live sprites, count pulse, spring easing — all reduced-motion aware); real
  app icon (glowing crab, build/icon.icns via headless-Chrome+iconutil);
  ⌘1–9 answers pending questions from anywhere (iTerm write-text; other
  terminals via Accessibility keystroke once granted; else jump), options
  clickable in the ask card; first-run ONBOARDING window (animated island
  demo, Accessibility + login steps, flag at userData/onboarded); TRAY-LESS
  by default (AGENT_ISLAND_TRAY=1 restores) — sounds/quit live in the panel
  footer, hover the notch to reach them.
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

## Living Island (spec: docs/superpowers/specs/2026-07-25-living-island-design.md)

Staged deliberately: Stage A carries everything that touches existing behavior,
Stage B is nearly additive.

- **Stage A — DONE 2026-07-25** (branch `feat/living-island`): adaptive expanded
  width (measured content, 360–720px), the native Swift sidecar
  (`native/AgentIslandNative.swift`, built by `scripts/build-native.sh`),
  trackpad haptics with 8 rhythms + 250ms coalescing, VoiceOver reach-in via
  ⌃⌥⌘I with a focus trap, keyboard-reachable session rows, polite/assertive live
  regions, `prefers-contrast` + `prefers-reduced-transparency` support, and a
  text-size setting over 9 type tokens in `styles/tokens.css`.
  Fixed two pre-existing bugs it exposed: the cursor watcher tested the *window*
  rect rather than the island's, and the window origin was computed once so
  display changes left it off-centre.
  **Not verified by machine:** whether the trackpad physically taps (needs a
  hand on a Force Touch trackpad) and the ⌃⌥⌘I keystroke end-to-end (no input
  injection available in the dev sandbox; registration itself is confirmed).
- **Stage B — not started**: weather. Adds the first ongoing network call
  (Open-Meteo, no API key), CoreLocation via the same sidecar with a
  timezone-table fallback (`/var/db/timezone/zoneinfo/zone.tab`), and ten
  animated conditions. **Blocks on rewriting the README privacy section** —
  README.md:72-82 currently promises the GitHub version check is the single
  network exception, which Stage B makes false.

## Next up (agreed backlog, in rough priority)

1. **Stability + size reduction** (user's stated goal 2026-07-19): shrink
   DMG/app further. NOTE: Stage A above works against this — it adds a ~94KB
   Swift binary and ~400 lines of CSS. Accepted knowingly; no image or font
   assets were added. Done so far: en-only electronLanguages + framework
   locale trim (114->100MB), react/react-dom out of the packed asar, old
   release/ artifacts cleaned (357MB). Remaining ideas: prune asar further,
   Electron upgrade, asar unpack audit.
2. **Releases/CI — DONE 2026-07-19**: README.md, .github/workflows/ci.yml
   (typecheck+test on push/PR) and release.yml (tag v* -> macos-14 arm64
   build -> DMG attached to GitHub Release). v0.1.0 shipped. In-app SILENT
   auto-update still blocked on Apple Developer ID (electron-updater
   requires a valid signature on macOS) — until then users update from
   Releases.
3. Homebrew cask (free no-warning distribution) — user deferred.
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
