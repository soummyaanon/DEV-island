import { BrowserWindow, screen } from "electron";
import { join } from "node:path";

/** Overlay window size (logical px). Wide/tall enough for the expanded panel. */
const WIN_WIDTH = 460;
const WIN_HEIGHT = 360;

/**
 * The Dynamic Island overlay: a transparent, always-on-top, click-through window
 * pinned to the top-center of the primary display (over the notch). The renderer
 * draws the pill/panel; everything else is transparent. Mouse events are ignored
 * (but forwarded) so the desktop stays clickable — the renderer flips
 * interactivity on when the pointer is over the pill.
 */
export function createNotchWindow(): BrowserWindow {
  const primary = screen.getPrimaryDisplay();
  const x = Math.round(primary.bounds.x + (primary.bounds.width - WIN_WIDTH) / 2);
  const y = primary.bounds.y; // flush to the very top, over the notch

  const win = new BrowserWindow({
    width: WIN_WIDTH,
    height: WIN_HEIGHT,
    x,
    y,
    frame: false,
    transparent: true,
    backgroundColor: "#00000000",
    resizable: false,
    movable: false,
    minimizable: false,
    maximizable: false,
    fullscreenable: false,
    skipTaskbar: true,
    hasShadow: false,
    focusable: false,
    alwaysOnTop: true,
    webPreferences: {
      preload: join(__dirname, "../preload/index.js"),
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: false,
    },
  });

  // Float above full-screen apps and on every Space.
  win.setAlwaysOnTop(true, "screen-saver");
  win.setVisibleOnAllWorkspaces(true, { visibleOnFullScreen: true });
  // Start click-through; renderer toggles this when the pointer is over the pill.
  win.setIgnoreMouseEvents(true, { forward: true });

  if (process.env.ELECTRON_RENDERER_URL) {
    win.loadURL(process.env.ELECTRON_RENDERER_URL);
  } else {
    win.loadFile(join(__dirname, "../renderer/index.html"));
  }

  return win;
}
