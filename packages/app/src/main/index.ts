import { app, BrowserWindow, ipcMain, type Tray } from "electron";
import type { SessionSnapshot } from "@agent-island/shared";
import { DaemonClient } from "./daemon-client";
import { createNotchWindow } from "./windows/notch-window";
import { createTray, updateTrayTitle } from "./tray";
import { jumpToTerminal } from "./jump-back";

// One instance only — two overlays fighting over the notch would be chaos.
if (!app.requestSingleInstanceLock()) {
  app.quit();
} else {
  let notch: BrowserWindow | null = null;
  let tray: Tray | null = null;
  const daemon = new DaemonClient();

  app.whenReady().then(() => {
    app.dock?.hide(); // menu-bar app, no Dock icon
    notch = createNotchWindow();
    tray = createTray(
      () => notch?.webContents.send("agent-island:toggle"),
      () => app.quit(),
    );

    daemon.onSessions((sessions: SessionSnapshot[], connected: boolean) => {
      notch?.webContents.send("agent-island:sessions", { sessions, connected });
      if (tray) updateTrayTitle(tray, sessions);
    });
    daemon.start();

    // Renderer pulls initial state on mount (it may load after the first push).
    ipcMain.handle("agent-island:get-sessions", () => ({
      sessions: daemon.list(),
      connected: daemon.isConnected(),
    }));

    // Renderer toggles click-through as the pointer enters/leaves the pill.
    ipcMain.on("agent-island:set-interactive", (_e, interactive: boolean) => {
      notch?.setIgnoreMouseEvents(!interactive, { forward: true });
    });

    ipcMain.on("agent-island:jump", (_e, session: SessionSnapshot) => jumpToTerminal(session));

    ipcMain.on("agent-island:quit", () => app.quit());
  });

  // Keep running with no windows — this is a menu-bar/overlay app.
  app.on("window-all-closed", () => {
    /* stay alive */
  });

  app.on("before-quit", () => daemon.stop());
}
