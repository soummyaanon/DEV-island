import { app, BrowserWindow, globalShortcut, ipcMain, screen, type Tray } from "electron";
import type { ApprovalDecision, SessionSnapshot } from "@agent-island/shared";
import { DaemonClient } from "./daemon-client";
import { ensureDaemon, stopDaemon } from "./daemon-manager";
import { setupZeroConfig } from "./zero-config";
import { createNotchWindow } from "./windows/notch-window";
import { createTray, updateTrayTitle } from "./tray";
import { jumpToTerminal } from "./jump-back";

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

  app.whenReady().then(async () => {
    app.dock?.hide(); // menu-bar app, no Dock icon
    notch = createNotchWindow();

    let soundsOn = true;
    tray = createTray({
      onToggle: () => sendToNotch("agent-island:toggle"),
      onQuit: () => app.quit(),
      isSoundOn: () => soundsOn,
      onToggleSound: (on) => {
        soundsOn = on;
        sendToNotch("agent-island:sounds", on);
      },
    });
    ipcMain.handle("agent-island:get-sounds", () => soundsOn);

    // Zero Config: wire Claude Code to the daemon (token + safe hook merge).
    setupZeroConfig();

    // One launch runs everything: spawn the daemon if it isn't already up.
    await ensureDaemon();

    daemon.onSessions((sessions: SessionSnapshot[], connected: boolean) => {
      sendToNotch("agent-island:sessions", { sessions, connected });
      if (tray && !tray.isDestroyed()) updateTrayTitle(tray, sessions);
      syncApprovalShortcuts(sessions);
    });
    daemon.onUsage((usage) => sendToNotch("agent-island:usage", usage));
    daemon.start();

    // Renderer pulls initial state on mount (it may load after the first push).
    ipcMain.handle("agent-island:get-sessions", () => ({
      sessions: daemon.list(),
      connected: daemon.isConnected(),
    }));
    ipcMain.handle("agent-island:get-usage", () => daemon.getUsage());

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
    daemon.stop();
    stopDaemon();
  });
}
