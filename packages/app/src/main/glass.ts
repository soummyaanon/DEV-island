import type { BrowserWindow } from "electron";
import { onLine, send } from "./native-helper";

/**
 * Liquid Glass under the expanded panel.
 *
 * CSS cannot do this: `backdrop-filter` in a transparent Electron window only
 * sees the page, never the wallpaper. So the native sidecar owns a borderless,
 * click-through NSPanel holding an NSGlassEffectView (macOS 26) or an
 * NSVisualEffectView (older), ordered directly BELOW the Electron window and
 * sized to the panel's rect. The renderer reports that rect every frame during
 * its spring transition (ResizeObserver, rAF-coalesced), and this module
 * forwards it — so the glass tracks the CSS motion one frame behind at most.
 *
 * The notch band stays pure black in CSS; only the panel below it is glass.
 * Absence of the helper, an unsupported OS, "Reduce transparency", "Increase
 * contrast", or the user's toggle all resolve to the CSS tier — never an error.
 */

export type GlassSupport = "native" | "vibrancy" | "none";

export interface Rect {
  x: number;
  y: number;
  width: number;
  height: number;
}

export interface MediaPrefs {
  reducedTransparency: boolean;
  moreContrast: boolean;
}

/** Corner radius of the expanded island (island.css `.island.expanded`). */
export const GLASS_RADIUS = 16;
/** How far the glass tucks up under the black band so its top corners are hidden. */
export const GLASS_OVERLAP = 6;

/**
 * Screen rect for the glass, from the window's bounds and the panel's rect in
 * window coordinates. Null when there is nothing to glass (collapsed).
 */
export function glassFrame(windowBounds: Rect, panelRect: Rect | null, overlap = GLASS_OVERLAP): Rect | null {
  if (!panelRect || panelRect.height <= 2 || panelRect.width <= 0) return null;
  return {
    x: Math.round(windowBounds.x + panelRect.x),
    y: Math.round(windowBounds.y + panelRect.y - overlap),
    width: Math.round(panelRect.width),
    height: Math.round(panelRect.height + overlap),
  };
}

/** `glass native` | `glass vibrancy` | `glass none` → support tier; anything else null. */
export function parseGlassCaps(line: string): GlassSupport | null {
  const m = /^glass (native|vibrancy|none)$/.exec(line.trim());
  return m ? (m[1] as GlassSupport) : null;
}

/** Electron's `getMediaSourceId()` is `window:<CGWindowID>:0`. 0 when unparseable. */
export function parseWindowId(mediaSourceId: string): number {
  const m = /^window:(\d+):/.exec(mediaSourceId);
  const id = m ? Number(m[1]) : 0;
  return Number.isFinite(id) && id > 0 ? id : 0;
}

let support: GlassSupport = "none";
let enabled = true;
let media: MediaPrefs = { reducedTransparency: false, moreContrast: false };
let windowId = 0;
let lastCommand = "";
let supportListeners: Array<(support: GlassSupport) => void> = [];

/** Whether the native panel should be shown at all right now. */
export function glassActive(): boolean {
  return enabled && support !== "none" && !media.reducedTransparency && !media.moreContrast;
}

export function glassSupport(): GlassSupport {
  return support;
}

/** The tier the renderer should style for: the native material, or CSS. */
export function glassTier(): "native" | "vibrancy" | "css" {
  return glassActive() ? (support as "native" | "vibrancy") : "css";
}

export function onGlassSupport(listener: (support: GlassSupport) => void): () => void {
  supportListeners.push(listener);
  return () => {
    supportListeners = supportListeners.filter((l) => l !== listener);
  };
}

/** Ask the sidecar what it can do and remember which window to sit beneath. */
export function initGlass(win: BrowserWindow): void {
  windowId = parseWindowId(win.getMediaSourceId());
  onLine((line) => {
    const caps = parseGlassCaps(line);
    if (!caps) return;
    support = caps;
    console.log(`[glass] support=${caps} belowWindow=${windowId}`);
    for (const l of supportListeners) l(caps);
  });
  // False = helper absent; support stays "none" and the CSS tier carries it.
  if (!send("glass caps")) console.log("[glass] native helper unavailable — CSS tier");
}

export function setGlassEnabled(on: boolean): void {
  enabled = on;
  if (!glassActive()) hideGlass();
}

export function setGlassMediaPrefs(prefs: MediaPrefs): void {
  media = prefs;
  if (!glassActive()) hideGlass();
}

/** Follow the panel. Deduplicated: identical frames are not re-sent. */
export function updateGlass(windowBounds: Rect, panelRect: Rect | null): void {
  if (!glassActive()) return;
  const frame = glassFrame(windowBounds, panelRect);
  if (!frame) {
    hideGlass();
    return;
  }
  const command = `glass show ${frame.x} ${frame.y} ${frame.width} ${frame.height} ${GLASS_RADIUS} ${windowId}`;
  if (command === lastCommand) return;
  lastCommand = command;
  send(command);
}

export function hideGlass(): void {
  if (lastCommand === "") return;
  lastCommand = "";
  send("glass hide");
}
