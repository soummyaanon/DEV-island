import { BrowserWindow, ipcMain, screen } from "electron";
import { join } from "node:path";

/** Overlay window size (logical px). Wide/tall enough for the expanded panel. */
const WIN_WIDTH = 460;
const WIN_HEIGHT = 400;

/**
 * The Dynamic Island overlay: a transparent, always-on-top, click-through window
 * pinned to the top-center of the primary display (over the notch). The renderer
 * draws the pill/panel; everything else is transparent. Mouse events are ignored
 * (but forwarded) so the desktop stays clickable — the renderer flips
 * interactivity on when the pointer is over the pill.
 *
 * Hug geometry: we ask for y = screen top, then MEASURE where macOS actually
 * placed the window. The renderer receives `inset` = distance from the window's
 * top to the menu bar's bottom edge (the notch's bottom line) and pads the
 * capsule by exactly that much — so the black body merges with the notch and
 * the content starts flush under it, on any display, no magic numbers.
 */
export function createNotchWindow(): BrowserWindow {
  const primary = screen.getPrimaryDisplay();
  const x = Math.round(primary.bounds.x + (primary.bounds.width - WIN_WIDTH) / 2);
  // Full screen frame, NOT workArea: the shape must cover the menu-bar band so
  // it merges with the hardware notch. A normal NSWindow gets clamped below
  // the menu bar (the source of our floating gaps) — an NSPanel does not,
  // which is why `type: "panel"` below is load-bearing.
  const y = primary.bounds.y;

  const win = new BrowserWindow({
    width: WIN_WIDTH,
    height: WIN_HEIGHT,
    x,
    y,
    type: "panel",
    enableLargerThanScreen: true,
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
      // Trim renderer features this overlay never uses.
      spellcheck: false,
      webgl: false,
      backgroundThrottling: true,
    },
  });

  // Float above full-screen apps and on every Space; keep it out of Mission
  // Control (mirrors NSPanel collectionBehavior in the reference).
  win.setAlwaysOnTop(true, "screen-saver");
  win.setVisibleOnAllWorkspaces(true, { visibleOnFullScreen: true });
  win.setHiddenInMissionControl?.(true);
  // Start click-through; renderer toggles this when the pointer is over the pill.
  win.setIgnoreMouseEvents(true, { forward: true });

  const layout = () => {
    // Menu bar bottom (= the notch's bottom line) relative to where the window
    // actually ended up. macOS sometimes nudges non-focusable overlay windows,
    // so measure rather than assume.
    const actualY = win.getBounds().y;
    const menuBarBottom = primary.workArea.y;
    return { inset: Math.max(0, menuBarBottom - actualY) };
  };

  const pushLayout = () => {
    // Re-assert the requested position (macOS can shift it on show), then tell
    // the renderer the real geometry.
    win.setPosition(x, y);
    const l = layout();
    console.log(
      `[notch] windowY=${win.getBounds().y} menuBarBottom=${primary.workArea.y} inset=${l.inset}`,
    );
    win.webContents.send("agent-island:layout", l);
  };

  ipcMain.handle("agent-island:get-layout", () => layout());
  win.webContents.on("did-finish-load", () => {
    pushLayout();
    // Once more after the window settles — the first show can reposition it.
    setTimeout(pushLayout, 400);
  });

  if (process.env.ELECTRON_RENDERER_URL) {
    win.loadURL(process.env.ELECTRON_RENDERER_URL);
  } else {
    win.loadFile(join(__dirname, "../renderer/index.html"));
  }

  return win;
}
