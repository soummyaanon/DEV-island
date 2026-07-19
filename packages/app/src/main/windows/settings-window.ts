import { BrowserWindow } from "electron";
import { join } from "node:path";

let win: BrowserWindow | null = null;

/** Open (or focus) the Settings window. */
export function showSettingsWindow(): void {
  if (win && !win.isDestroyed()) {
    win.show();
    win.focus();
    return;
  }
  win = new BrowserWindow({
    width: 470,
    height: 700,
    show: false,
    frame: false,
    transparent: true,
    backgroundColor: "#00000000",
    resizable: false,
    maximizable: false,
    minimizable: true,
    fullscreenable: false,
    hasShadow: true,
    webPreferences: {
      preload: join(__dirname, "../preload/index.js"),
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: false,
      spellcheck: false,
    },
  });
  win.center();

  if (process.env.ELECTRON_RENDERER_URL) {
    void win.loadURL(`${process.env.ELECTRON_RENDERER_URL}/settings.html`);
  } else {
    void win.loadFile(join(__dirname, "../renderer/settings.html"));
  }
  win.once("ready-to-show", () => {
    win?.show();
    win?.focus();
  });
  win.on("closed", () => {
    win = null;
  });
}

/** Push fresh state to the window if it's open (after any settings change). */
export function pushSettingsState(state: unknown): void {
  if (win && !win.isDestroyed()) win.webContents.send("agent-island:settings-state", state);
}
