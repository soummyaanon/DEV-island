import { app, BrowserWindow, globalShortcut, ipcMain, screen, type Tray } from "electron";
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
import { loadSettings, saveSettings } from "./settings";
import { createTray, updateTrayTitle } from "./tray";
import { answerInTerminal, jumpToTerminal } from "./jump-back";
import { openUpdatePage, startUpdateCheck, stopUpdateCheck } from "./update-check";

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
        if (pendingApprovalId) void daemon.resolveApproval(pendingApprovalId, "allow");
      });
      globalShortcut.register("CommandOrControl+N", () => {
        if (pendingApprovalId) void daemon.resolveApproval(pendingApprovalId, "deny");
      });
    }
  }

  // While an agent waits on a multiple-choice question, ⌘1..⌘9 answer it from
  // anywhere (registered only for the shown options, released the moment the
  // question clears — same transient pattern as the ⌘Y/⌘N approvals).
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
    if (!session || !q) return;
    questionKeyCount = Math.min(9, q.options.length);
    for (let i = 1; i <= questionKeyCount; i++) {
      globalShortcut.register(`CommandOrControl+${i}`, () => answerInTerminal(session, String(i)));
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

    function settingsState() {
      return {
        ...settings,
        openAtLogin: app.getLoginItemSettings().openAtLogin,
        version: app.getVersion(),
      };
    }

    function pushFiltered(): void {
      sendToNotch("agent-island:sessions", {
        sessions: filterSessions(daemon.list()),
        connected: daemon.isConnected(),
      });
      sendToNotch("agent-island:usage", filterUsage(daemon.getUsage()));
    }

    /** The one place a setting changes: persist, apply side effects, broadcast. */
    function applySetting(key: string, value: boolean): void {
      switch (key) {
        case "agent:claude-code":
          settings.agents["claude-code"] = value;
          if (value) setupZeroConfig();
          else removeClaudeHooks();
          break;
        case "agent:codex":
          settings.agents.codex = value; // read-only tailer; hiding it is disconnecting
          break;
        case "agent:cursor":
          settings.agents.cursor = value;
          if (value) setupCursorZeroConfig();
          else removeCursorHooks();
          break;
        case "sounds":
          settings.sounds = value;
          sendToNotch("agent-island:sounds", value);
          break;
        case "tray":
          settings.tray = value;
          syncTray();
          break;
        case "updateCheck":
          settings.updateCheck = value;
          if (value) startUpdateCheck(onUpdateInfo);
          else stopUpdateCheck();
          break;
        case "openAtLogin":
          app.setLoginItemSettings({ openAtLogin: value, openAsHidden: true });
          break;
        default:
          return;
      }
      saveSettings(settings);
      pushSettingsState(settingsState());
      pushFiltered();
    }

    ipcMain.handle("agent-island:get-sounds", () => settings.sounds);
    ipcMain.on("agent-island:set-sounds", (_e, on: boolean) => applySetting("sounds", on));
    ipcMain.handle("agent-island:get-settings", () => settingsState());
    ipcMain.on("agent-island:set-setting", (_e, { key, value }: { key: string; value: boolean }) =>
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

    ipcMain.on("agent-island:jump", (_e, session: SessionSnapshot) => jumpToTerminal(session));

    ipcMain.on(
      "agent-island:answer",
      (_e, { session, digit }: { session: SessionSnapshot; digit: number }) =>
        answerInTerminal(session, String(digit)),
    );

    ipcMain.on(
      "agent-island:approve",
      (_e, { id, decision }: { id: string; decision: ApprovalDecision }) => {
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
    daemon.stop();
    stopDaemon();
  });
}
