import { app, BrowserWindow } from "electron";
import { join } from "node:path";
import { attachEditShortcuts } from "../edit-shortcuts";

let win: BrowserWindow | null = null;
/** The size the user last left it at this run; a fresh launch starts at the default. */
let lastSize: { width: number; height: number } | null = null;

const WIN_W = 780;
const WIN_H = 500;
const MIN_W = 640;
const MIN_H = 400;

/**
 * Open (or focus) the Settings window.
 *
 * A real macOS window, System Settings style: native traffic lights (close,
 * minimize, zoom / full screen) over a hidden-inset title bar, native resize
 * with a sensible minimum, Mission Control and Spaces behaviour for free, and a
 * vibrant sidebar the renderer leaves transparent. The old frameless,
 * transparent card had to fake all of that — and its first click was routinely
 * swallowed by window activation (this app has no Dock icon, so it is usually
 * inactive when Settings opens from the island), which read as "toggles need
 * two clicks". `acceptFirstMouse` delivers that click to the page, and
 * `app.focus({ steal: true })` makes the window key on open regardless.
 *
 * Full screen needs one more thing: macOS never gives an accessory app (no
 * Dock icon) a full-screen Space — its green button only zooms. So the app
 * becomes a regular one for as long as Settings is open (Dock icon and ⌘-Tab
 * entry included, the way menu-bar apps do it) and steps back to accessory
 * when the window closes.
 */
export function showSettingsWindow(): void {
  console.log(`[settings] open requested (${win && !win.isDestroyed() ? "reuse" : "create"})`);
  app.setActivationPolicy("regular");
  if (win && !win.isDestroyed()) {
    if (win.isMinimized()) win.restore();
    app.focus({ steal: true });
    win.show();
    win.focus();
    return;
  }
  win = new BrowserWindow({
    width: lastSize?.width ?? WIN_W,
    height: lastSize?.height ?? WIN_H,
    minWidth: MIN_W,
    minHeight: MIN_H,
    show: false,
    title: "Agent Island Settings",
    titleBarStyle: "hiddenInset",
    vibrancy: "sidebar",
    backgroundColor: "#00000000",
    resizable: true,
    minimizable: true,
    maximizable: true,
    fullscreenable: true,
    acceptFirstMouse: true,
    webPreferences: {
      preload: join(__dirname, "../preload/index.js"),
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: false,
      spellcheck: false,
    },
  });
  attachEditShortcuts(win.webContents);
  win.center();

  if (process.env.ELECTRON_RENDERER_URL) {
    void win.loadURL(`${process.env.ELECTRON_RENDERER_URL}/settings.html`);
  } else {
    void win.loadFile(join(__dirname, "../renderer/settings.html"));
  }
  win.once("ready-to-show", () => {
    app.focus({ steal: true });
    win?.show();
    win?.focus();
    console.log(`[settings] shown ${win?.getBounds().width}x${win?.getBounds().height} focused=${win?.isFocused()}`);
  });
  win.webContents.on("did-fail-load", (_e, code, desc) => console.warn(`[settings] load failed: ${code} ${desc}`));
  // Remember a normal size only — not the full-screen or zoomed one.
  win.on("close", () => {
    if (win && !win.isDestroyed() && !win.isFullScreen() && !win.isMaximized()) {
      const { width, height } = win.getBounds();
      lastSize = { width, height };
    }
  });
  win.on("closed", () => {
    console.log("[settings] closed");
    win = null;
    app.setActivationPolicy("accessory");
  });
}

/** Push fresh state to the window if it's open (after any settings change). */
export function pushSettingsState(state: unknown): void {
  if (win && !win.isDestroyed()) win.webContents.send("agent-island:settings-state", state);
}
