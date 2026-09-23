import { BrowserWindow, ipcMain, screen } from "electron";
import { execFile } from "node:child_process";
import { join } from "node:path";
import { attachEditShortcuts } from "../edit-shortcuts";

/**
 * Overlay window size (logical px) — deliberately far larger than the visible
 * island. The expanded panel sizes itself to its content up to
 * MAX_ISLAND_WIDTH, and the window has to be able to contain the widest case;
 * everything outside the island is transparent and click-through, so the spare
 * area costs nothing. Height allows a tall question card at the largest text
 * scale.
 */
const WIN_WIDTH = 820;
const WIN_HEIGHT = 560;

/** Ceiling for the expanded island, before the per-display clamp. */
const MAX_ISLAND_WIDTH = 720;

/**
 * Measure the hardware notch width in logical px. Electron has no API for it,
 * but JXA can bridge into AppKit: the notch is the gap between NSScreen's two
 * auxiliary top areas (the menu-bar "wings"). Resolves 0 on Macs without a
 * notch, on external displays, or on any error — callers fall back to a
 * sensible default so this can never break the overlay.
 */
function measureNotchWidth(): Promise<number> {
  const jxa = `
    ObjC.import("AppKit");
    const s = $.NSScreen.mainScreen;
    const l = s.auxiliaryTopLeftArea;
    const r = s.auxiliaryTopRightArea;
    if (!l || !r) "0";
    else String(Math.round(s.frame.size.width - l.size.width - r.size.width));`;
  return new Promise((resolve) => {
    execFile("osascript", ["-l", "JavaScript", "-e", jxa], { timeout: 3000 }, (err, stdout) => {
      if (err) return resolve(0);
      const width = Number(stdout.trim());
      // Sanity band: a real notch is roughly 120–260 logical px.
      resolve(Number.isFinite(width) && width >= 120 && width <= 260 ? width : 0);
    });
  });
}

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
/**
 * Where the window belongs right now. Recomputed rather than captured, because
 * a resolution change, a display swap, or docking moves the notch — and the
 * origin used to be calculated once at creation, which left the island
 * permanently off-centre after any of those.
 */
function targetOrigin(): { x: number; y: number } {
  const primary = screen.getPrimaryDisplay();
  return {
    x: Math.round(primary.bounds.x + (primary.bounds.width - WIN_WIDTH) / 2),
    // Full screen frame, NOT workArea: the shape must cover the menu-bar band
    // so it merges with the hardware notch. A normal NSWindow gets clamped
    // below the menu bar (the source of our floating gaps) — an NSPanel does
    // not, which is why `type: "panel"` below is load-bearing.
    y: primary.bounds.y,
  };
}

export function createNotchWindow(): BrowserWindow {
  const origin = targetOrigin();

  const win = new BrowserWindow({
    width: WIN_WIDTH,
    height: WIN_HEIGHT,
    x: origin.x,
    y: origin.y,
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
  attachEditShortcuts(win.webContents);

  // Float above full-screen apps and on every Space; keep it out of Mission
  // Control (mirrors NSPanel collectionBehavior in the reference).
  win.setAlwaysOnTop(true, "screen-saver");
  win.setVisibleOnAllWorkspaces(true, { visibleOnFullScreen: true });
  win.setHiddenInMissionControl?.(true);
  // Start click-through; renderer toggles this when the pointer is over the pill.
  win.setIgnoreMouseEvents(true, { forward: true });

  // Measured once at startup; 0 until resolved (renderer keeps its default).
  let notchWidth = 0;
  void measureNotchWidth().then((width) => {
    notchWidth = width;
    if (!win.isDestroyed()) pushLayout();
  });

  const layout = () => {
    // Menu bar bottom (= the notch's bottom line) relative to where the window
    // actually ended up. macOS sometimes nudges non-focusable overlay windows,
    // so measure rather than assume.
    const primary = screen.getPrimaryDisplay();
    const actualY = win.getBounds().y;
    const menuBarBottom = primary.workArea.y;
    return {
      inset: Math.max(0, menuBarBottom - actualY),
      notchWidth,
      // The renderer grows the island to fit its content; this is the ceiling,
      // kept here because it depends on the display we're centred on.
      maxIslandWidth: Math.min(MAX_ISLAND_WIDTH, primary.bounds.width - 80),
    };
  };

  const pushLayout = () => {
    // Re-assert the requested position (macOS can shift it on show, and the
    // display geometry may have changed), then tell the renderer the reality.
    if (win.isDestroyed()) return;
    const { x, y } = targetOrigin();
    win.setPosition(x, y);
    const l = layout();
    console.log(
      `[notch] windowY=${win.getBounds().y} inset=${l.inset} notchWidth=${l.notchWidth} maxIsland=${l.maxIslandWidth}`,
    );
    win.webContents.send("agent-island:layout", l);
  };

  ipcMain.handle("agent-island:get-layout", () => layout());
  win.webContents.on("did-finish-load", () => {
    pushLayout();
    // Once more after the window settles — the first show can reposition it.
    setTimeout(pushLayout, 400);
  });

  // Display changes move the notch: re-measure it and re-centre. Without this
  // the island stays wherever the boot-time geometry put it.
  const onDisplayChange = (): void => {
    if (win.isDestroyed()) return;
    void measureNotchWidth().then((width) => {
      if (width > 0) notchWidth = width;
      pushLayout();
    });
  };
  // Listed one by one: Electron types `screen.on` as overloads per event name,
  // so a loop over a union of names doesn't type-check.
  screen.on("display-metrics-changed", onDisplayChange);
  screen.on("display-added", onDisplayChange);
  screen.on("display-removed", onDisplayChange);
  // Pin the island over the notch. macOS's "click wallpaper to reveal desktop"
  // (and Stage Manager, and a stray Mission Control shuffle) slides EVERY
  // window aside — this overlay included, which sent the island to the bottom
  // of the screen. Electron can't mark a window stationary, so it snaps back:
  // on every move event, plus a cheap check in case a move reports nothing.
  const pin = (): void => {
    if (win.isDestroyed()) return;
    const { x, y } = targetOrigin();
    const b = win.getBounds();
    // A real displacement only. macOS may hold the window a menu bar's height
    // lower than asked on some displays (that's what `inset` measures), and
    // re-asking every half second would fight it forever.
    if (Math.abs(b.x - x) > 2 || Math.abs(b.y - y) > 60) {
      win.setBounds({ x, y, width: WIN_WIDTH, height: WIN_HEIGHT });
    }
  };
  win.on("move", pin);
  win.on("moved", pin);
  const pinTimer = setInterval(pin, 500);
  win.on("closed", () => {
    clearInterval(pinTimer);
    screen.removeListener("display-metrics-changed", onDisplayChange);
    screen.removeListener("display-added", onDisplayChange);
    screen.removeListener("display-removed", onDisplayChange);
  });

  if (process.env.ELECTRON_RENDERER_URL) {
    win.loadURL(process.env.ELECTRON_RENDERER_URL);
  } else {
    win.loadFile(join(__dirname, "../renderer/index.html"));
  }

  return win;
}
