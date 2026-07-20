import { app, BrowserWindow, dialog, globalShortcut, ipcMain, screen, type Tray } from "electron";
import { copyFileSync, existsSync, mkdirSync, readFileSync, rmSync } from "node:fs";
import { basename, extname, join } from "node:path";
import type { AgentUsage, ApprovalDecision, SessionSnapshot } from "@agent-island/shared";
import { DaemonClient } from "./daemon-client";
import { ensureDaemon, stopDaemon } from "./daemon-manager";
import {
  removeClaudeHooks,
  removeCursorHooks,
  setupCursorZeroConfig,
  setupZeroConfig,
} from "./zero-config";
import { createNotchWindow } from "./windows/notch-window";
import { maybeShowOnboarding, registerOnboardingIpc } from "./windows/onboarding-window";
import { pushSettingsState, showSettingsWindow } from "./windows/settings-window";
import { isSoundEvent, isSoundTheme, loadSettings, saveSettings } from "./settings";
import { createTray, updateTrayTitle } from "./tray";
import { answerInTerminal, jumpToTerminal, sendPromptToTerminal } from "./jump-back";
import {
  checkNow,
  downloadAndInstall,
  getPendingUpdate,
  openUpdatePage,
  startUpdateCheck,
  stopUpdateCheck,
} from "./update-check";

// One instance only — two overlays fighting over the notch would be chaos.
if (!app.requestSingleInstanceLock()) {
  app.quit();
} else {
  // Memory: drop the GPU process — macOS software-composites the transparent
  // overlay fine — and cap V8 heap growth across the app.
  app.disableHardwareAcceleration();
  app.commandLine.appendSwitch("js-flags", "--max-old-space-size=96");

  let notch: BrowserWindow | null = null;
  let tray: Tray | null = null;
  const daemon = new DaemonClient();

  // During quit the window object outlives its native counterpart; sending to a
  // destroyed webContents throws "Object has been destroyed".
  function sendToNotch(channel: string, ...args: unknown[]): void {
    if (notch && !notch.isDestroyed()) notch.webContents.send(channel, ...args);
  }

  // ⌘Y / ⌘N resolve a pending approval. The notch window is non-focusable, so we
  // use global shortcuts — registered only while an approval is actually pending.
  let pendingApprovalId: string | null = null;
  function syncApprovalShortcuts(sessions: SessionSnapshot[]): void {
    const id = sessions.find((s) => s.pending_approval)?.pending_approval?.id ?? null;
    if (id === pendingApprovalId) return;
    pendingApprovalId = id;
    globalShortcut.unregister("CommandOrControl+Y");
    globalShortcut.unregister("CommandOrControl+N");
    if (id) {
      globalShortcut.register("CommandOrControl+Y", () => {
        if (!pendingApprovalId) return;
        sendToNotch("agent-island:chime", "approve");
        void daemon.resolveApproval(pendingApprovalId, "allow");
      });
      globalShortcut.register("CommandOrControl+N", () => {
        if (pendingApprovalId) void daemon.resolveApproval(pendingApprovalId, "deny");
      });
    }
  }

  // Claude questions are answered through the daemon's held hook — no terminal
  // focus or synthetic keystrokes needed. Codex (and an expired hold) falls
  // back to jump + keystrokes (single-question only; multi just jumps).
  async function answerQuestion(session: SessionSnapshot, options: number[]): Promise<void> {
    const q = session.pending_question;
    if (q && session.agent === "claude-code" && (await daemon.answerQuestion(q.id, options))) {
      console.log(`[jump] answered ${q.id} via hook (${options.join(",")})`);
      sendToNotch("agent-island:chime", "approve");
      return;
    }
    if (options.length === 1) answerInTerminal(session, String(options[0] + 1));
    else jumpToTerminal(session);
  }

  // While an agent waits on a single multiple-choice question, ⌘1..⌘9 answer
  // it from anywhere (registered only for the shown options, released the
  // moment the question clears — same transient pattern as ⌘Y/⌘N approvals).
  // Multi-question cards are answered by clicking each choice on the island.
  let questionId: string | null = null;
  let questionKeyCount = 0;
  function syncQuestionShortcuts(sessions: SessionSnapshot[]): void {
    const session = sessions.find((s) => s.pending_question);
    const q = session?.pending_question ?? null;
    if ((q?.id ?? null) === questionId) return;
    for (let i = 1; i <= questionKeyCount; i++) {
      globalShortcut.unregister(`CommandOrControl+${i}`);
    }
    questionId = q?.id ?? null;
    questionKeyCount = 0;
    if (!session || !q || q.questions.length !== 1) return;
    questionKeyCount = Math.min(9, q.questions[0].options.length);
    for (let i = 1; i <= questionKeyCount; i++) {
      globalShortcut.register(`CommandOrControl+${i}`, () => void answerQuestion(session, [i - 1]));
    }
  }

  app.whenReady().then(async () => {
    app.dock?.hide(); // menu-bar app, no Dock icon
    notch = createNotchWindow();

    const settings = loadSettings();

    // Disabled integrations disappear everywhere the UI looks.
    const filterSessions = (sessions: SessionSnapshot[]): SessionSnapshot[] =>
      sessions.filter((s) => settings.agents[s.agent] !== false);
    const filterUsage = (usage: AgentUsage[]): AgentUsage[] =>
      usage.filter((u) => settings.agents[u.agent] !== false);

    // Menu-bar icon: a setting now (AGENT_ISLAND_TRAY=1 still forces it on).
    function syncTray(): void {
      const want = settings.tray || process.env.AGENT_ISLAND_TRAY === "1";
      if (want && !tray) {
        tray = createTray({
          onToggle: () => sendToNotch("agent-island:toggle"),
          onQuit: () => app.quit(),
          isSoundOn: () => settings.sounds,
          onToggleSound: (on) => applySetting("sounds", on),
        });
      } else if (!want && tray) {
        tray.destroy();
        tray = null;
      }
    }
    syncTray();

    const onUpdateInfo = (info: { version: string }): void =>
      sendToNotch("agent-island:update", info);

    const AUDIO_MIME: Record<string, string> = {
      ".mp3": "audio/mpeg",
      ".wav": "audio/wav",
      ".m4a": "audio/mp4",
      ".aac": "audio/aac",
      ".ogg": "audio/ogg",
      ".oga": "audio/ogg",
      ".aif": "audio/aiff",
      ".aiff": "audio/aiff",
      ".flac": "audio/flac",
    };
    /** Read each imported sound file into a data URL (the renderer is sandboxed
     *  and can't read arbitrary FS paths). Skips missing/unreadable files. */
    function customSoundData(): Record<string, string> {
      const out: Record<string, string> = {};
      for (const [event, path] of Object.entries(settings.customSounds)) {
        if (typeof path !== "string" || !existsSync(path)) continue;
        try {
          const mime = AUDIO_MIME[extname(path).toLowerCase()] ?? "audio/mpeg";
          out[event] = `data:${mime};base64,${readFileSync(path).toString("base64")}`;
        } catch {
          /* unreadable -> skip; the event falls back to its theme */
        }
      }
      return out;
    }

    function settingsState() {
      return {
        ...settings,
        customSounds: customSoundData(),
        openAtLogin: app.getLoginItemSettings().openAtLogin,
        version: app.getVersion(),
        update: getPendingUpdate(),
      };
    }

    function pushFiltered(): void {
      sendToNotch("agent-island:sessions", {
        sessions: filterSessions(daemon.list()),
        connected: daemon.isConnected(),
      });
      sendToNotch("agent-island:usage", filterUsage(daemon.getUsage()));
    }

    const soundPrefs = () => ({
      on: settings.sounds,
      theme: settings.soundTheme,
      overrides: settings.soundOverrides,
      custom: customSoundData(),
    });

    /** The one place a setting changes: persist, apply side effects, broadcast. */
    function applySetting(key: string, value: boolean | string): void {
      switch (key) {
        case "agent:claude-code":
          settings.agents["claude-code"] = value === true;
          if (value) setupZeroConfig();
          else removeClaudeHooks();
          break;
        case "agent:codex":
          settings.agents.codex = value === true; // read-only tailer; hiding it is disconnecting
          break;
        case "agent:cursor":
          settings.agents.cursor = value === true;
          if (value) setupCursorZeroConfig();
          else removeCursorHooks();
          break;
        case "sounds":
          settings.sounds = value === true;
          sendToNotch("agent-island:sounds", soundPrefs());
          break;
        case "soundTheme":
          if (!isSoundTheme(value)) return;
          settings.soundTheme = value;
          // A theme switch is a fresh start: per-event overrides reset so
          // every row follows the newly picked theme.
          settings.soundOverrides = {};
          sendToNotch("agent-island:sounds", soundPrefs());
          break;
        case "tray":
          settings.tray = value === true;
          syncTray();
          break;
        case "updateCheck":
          settings.updateCheck = value === true;
          if (value) startUpdateCheck(onUpdateInfo);
          else stopUpdateCheck();
          break;
        case "openAtLogin":
          app.setLoginItemSettings({ openAtLogin: value === true, openAsHidden: true });
          break;
        default: {
          // "soundOverride:<event>" — value is a theme, or "" for theme-default.
          const event = key.startsWith("soundOverride:") ? key.slice(14) : null;
          if (!isSoundEvent(event)) return;
          if (isSoundTheme(value)) settings.soundOverrides[event] = value;
          else delete settings.soundOverrides[event];
          sendToNotch("agent-island:sounds", soundPrefs());
          break;
        }
      }
      saveSettings(settings);
      pushSettingsState(settingsState());
      pushFiltered();
    }

    ipcMain.handle("agent-island:get-sounds", () => soundPrefs());
    ipcMain.on("agent-island:set-sounds", (_e, on: boolean) => applySetting("sounds", on));

    // Import a user's own audio file for one event: copy it into userData/sounds,
    // remember the path, and broadcast the new data URLs to the notch + settings.
    ipcMain.handle("agent-island:import-sound", async (_e, event: string) => {
      if (!isSoundEvent(event)) return false;
      const res = await dialog.showOpenDialog({
        title: "Choose a sound",
        properties: ["openFile"],
        filters: [
          { name: "Audio", extensions: ["mp3", "wav", "m4a", "aac", "ogg", "oga", "aif", "aiff", "flac"] },
        ],
      });
      if (res.canceled || res.filePaths.length === 0) return false;
      const src = res.filePaths[0];
      const dir = join(app.getPath("userData"), "sounds");
      const dest = join(dir, `${event}${extname(src).toLowerCase() || ".mp3"}`);
      const prev = settings.customSounds[event];
      try {
        mkdirSync(dir, { recursive: true });
        // A new extension would orphan the old file — remove it first.
        if (typeof prev === "string" && prev !== dest && existsSync(prev)) rmSync(prev);
        copyFileSync(src, dest);
      } catch (err) {
        console.error("[sound] import failed:", err);
        return false;
      }
      settings.customSounds[event] = dest;
      settings.customSoundNames[event] = basename(src);
      saveSettings(settings);
      sendToNotch("agent-island:sounds", soundPrefs());
      pushSettingsState(settingsState());
      return true;
    });

    ipcMain.on("agent-island:clear-sound", (_e, event: string) => {
      if (!isSoundEvent(event)) return;
      const prev = settings.customSounds[event];
      if (typeof prev === "string" && existsSync(prev)) {
        try {
          rmSync(prev);
        } catch {
          /* best-effort cleanup */
        }
      }
      delete settings.customSounds[event];
      delete settings.customSoundNames[event];
      saveSettings(settings);
      sendToNotch("agent-island:sounds", soundPrefs());
      pushSettingsState(settingsState());
    });
    ipcMain.handle("agent-island:get-settings", () => settingsState());
    // Settings "Check for updates" — run a check now and push the result back.
    ipcMain.handle("agent-island:check-updates", async () => {
      await checkNow(onUpdateInfo);
      pushSettingsState(settingsState());
      return getPendingUpdate();
    });
    // Settings "Install & Restart" — download the DMG and self-replace.
    ipcMain.handle("agent-island:install-update", () => downloadAndInstall());
    ipcMain.on("agent-island:set-setting", (_e, { key, value }: { key: string; value: boolean | string }) =>
      applySetting(key, value),
    );
    ipcMain.on("agent-island:open-settings", () => showSettingsWindow());

    // Traffic lights in frameless windows: act on whichever window asked.
    ipcMain.on("agent-island:win-close", (e) => BrowserWindow.fromWebContents(e.sender)?.close());
    ipcMain.on("agent-island:win-minimize", (e) =>
      BrowserWindow.fromWebContents(e.sender)?.minimize(),
    );

    // First launch: a short onboarding (island tour + Accessibility + login).
    registerOnboardingIpc();
    maybeShowOnboarding();

    // Update NOTIFIER (no self-update without a Developer ID): one anonymous
    // check against GitHub Releases; the island shows a chip, a notification
    // links to the download. Toggle in Settings; AGENT_ISLAND_NO_UPDATE_CHECK=1
    // still disables outright.
    if (settings.updateCheck) startUpdateCheck(onUpdateInfo);
    ipcMain.on("agent-island:open-update", () => openUpdatePage());

    // Zero Config: wire enabled agents to the daemon (token + safe hook
    // merges; Codex needs nothing — its rollout logs are tailed directly).
    if (settings.agents["claude-code"]) setupZeroConfig();
    if (settings.agents.cursor) setupCursorZeroConfig();

    // One launch runs everything: spawn the daemon if it isn't already up.
    await ensureDaemon();

    daemon.onSessions((sessions: SessionSnapshot[], connected: boolean) => {
      const visible = filterSessions(sessions);
      sendToNotch("agent-island:sessions", { sessions: visible, connected });
      if (tray && !tray.isDestroyed()) updateTrayTitle(tray, visible);
      syncApprovalShortcuts(visible);
      syncQuestionShortcuts(visible);
    });
    daemon.onUsage((usage) => sendToNotch("agent-island:usage", filterUsage(usage)));
    daemon.start();

    // Renderer pulls initial state on mount (it may load after the first push).
    ipcMain.handle("agent-island:get-sessions", () => ({
      sessions: filterSessions(daemon.list()),
      connected: daemon.isConnected(),
    }));
    ipcMain.handle("agent-island:get-usage", () => filterUsage(daemon.getUsage()));

    // Renderer toggles click-through as the pointer enters/leaves the pill.
    // While interactive, poll the real cursor so the island reliably collapses
    // the moment the pointer leaves the window (renderer-side mouse events
    // alone proved flaky and left it stuck open).
    let cursorWatch: ReturnType<typeof setInterval> | null = null;
    ipcMain.on("agent-island:set-interactive", (_e, interactive: boolean) => {
      console.log(`[notch] interactive=${interactive}`);
      if (notch && !notch.isDestroyed()) notch.setIgnoreMouseEvents(!interactive, { forward: true });
      if (cursorWatch) {
        clearInterval(cursorWatch);
        cursorWatch = null;
      }
      if (interactive) {
        cursorWatch = setInterval(() => {
          if (!notch || notch.isDestroyed()) return;
          const p = screen.getCursorScreenPoint();
          const b = notch.getBounds();
          const margin = 10;
          const inside =
            p.x >= b.x - margin &&
            p.x <= b.x + b.width + margin &&
            p.y >= b.y - margin &&
            p.y <= b.y + b.height + margin;
          if (!inside) sendToNotch("agent-island:cursor-left");
        }, 250);
      }
    });

    ipcMain.on("agent-island:jump", (_e, session: SessionSnapshot) => {
      console.log(`[jump] requested for ${session.key}`);
      jumpToTerminal(session);
    });

    ipcMain.on(
      "agent-island:answer",
      (_e, { session, options }: { session: SessionSnapshot; options: number[] }) => {
        console.log(`[jump] answer [${options.join(",")}] for ${session.key}`);
        void answerQuestion(session, options);
      },
    );

    ipcMain.on(
      "agent-island:send-prompt",
      (_e, { session, text }: { session: SessionSnapshot; text: string }) => {
        console.log(`[jump] send-prompt for ${session.key}`);
        const result = sendPromptToTerminal(session, text);
        // Tell the notch so it can show a hint instead of failing silently.
        sendToNotch("agent-island:prompt-status", result);
      },
    );

    // The overlay is created non-focusable so it never steals focus from the
    // terminal — but a non-focusable window can't become key, so keystrokes
    // never reach the prompt input. Flip focusable on only while composing.
    ipcMain.on("agent-island:prompt-composing", (_e, active: boolean) => {
      if (!notch || notch.isDestroyed()) return;
      console.log(`[notch] prompt-composing=${active}`);
      notch.setFocusable(active);
      if (active) notch.focus();
    });

    ipcMain.on(
      "agent-island:approve",
      (_e, { id, decision }: { id: string; decision: ApprovalDecision }) => {
        if (decision === "allow") sendToNotch("agent-island:chime", "approve");
        void daemon.resolveApproval(id, decision);
      },
    );

    ipcMain.on("agent-island:quit", () => app.quit());
  });

  // Keep running with no windows — this is a menu-bar/overlay app.
  app.on("window-all-closed", () => {
    /* stay alive */
  });

  app.on("before-quit", () => {
    globalShortcut.unregisterAll();
    stopUpdateCheck();
    // Remove our hooks before we go: the HTTP hooks point at the daemon we're
    // about to stop, so leaving them behind makes every subsequent Claude/Cursor
    // tool call error against a dead port. They're re-installed on next launch.
    removeClaudeHooks();
    removeCursorHooks();
    daemon.stop();
    stopDaemon();
  });
}
