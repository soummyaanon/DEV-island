---
name: electron-notch-overlay
description: Use when building a macOS Dynamic Island / notch overlay, notch-hugging HUD, or any always-on-top Electron window that must sit over the menu-bar band — especially when the window keeps getting clamped below the menu bar, floats with a visible gap under the notch, content gets clipped behind the physical notch, or a hover-expanded overlay gets stuck open.
---

# Electron Notch Overlay (Dynamic Island for macOS)

## Overview

AppKit clamps ordinary windows below the menu bar, so a naïve notch overlay
always floats with a gap. The fix is one flag: **`enableLargerThanScreen: true`**
(with `type: "panel"`) lets the window genuinely sit at `y = 0` over the
menu-bar band, so a black shape can start *behind the physical notch* and merge
with it. Measure geometry at runtime — never hardcode menu-bar heights.

## Evidence (measured, one 16" MBP, macOS 26 / Electron 35)

| Attempt | Result (win.getBounds().y vs menu bar bottom 33) |
|---|---|
| Normal BrowserWindow, `y: bounds.y` | clamped to **33** → visible gap under notch |
| CSS `margin-top: -18px` hack | content clipped **behind the physical notch** |
| `y: workArea.y` (flush below menu bar) | deterministic, but a hairline seam remains on scaled resolutions |
| `type: "panel"` alone | still clamped to **33** |
| `type: "panel"` + **`enableLargerThanScreen: true`** | **y = 0** — true hug ✅ |

Known limitation threads: [electron#47632](https://github.com/electron/electron/issues/47632).
Technique source: [electron-dynamic-island](https://github.com/IrtizaNasar/electron-dynamic-island).

## The Window (working config)

```ts
const primary = screen.getPrimaryDisplay();
const win = new BrowserWindow({
  width: 460, height: 400,
  x: Math.round(primary.bounds.x + (primary.bounds.width - 460) / 2),
  y: primary.bounds.y,            // FULL bounds, not workArea
  type: "panel",                  // NSPanel: required with the flag below
  enableLargerThanScreen: true,   // THE fix: disables AppKit frame clamping
  frame: false, transparent: true, backgroundColor: "#00000000",
  hasShadow: false, focusable: false, alwaysOnTop: true,
  resizable: false, movable: false, skipTaskbar: true, fullscreenable: false,
});
win.setAlwaysOnTop(true, "screen-saver");
win.setVisibleOnAllWorkspaces(true, { visibleOnFullScreen: true });
win.setHiddenInMissionControl?.(true);
win.setIgnoreMouseEvents(true, { forward: true }); // click-through when idle
```

**Verify, don't assume** — after `did-finish-load`, re-assert position and measure:

```ts
win.setPosition(x, y);
const inset = primary.workArea.y - win.getBounds().y; // notch-band height (e.g. 33)
win.webContents.send("layout", { inset }); // renderer pads content below the notch line
```

If `inset` is 0, the OS clamped you (older Electron / missing flag) — fall back
to a flush chin design instead of pretending.

## The Shape

- **Pure `#000`**, wider than the notch (notch ≈ 195–210 logical px on 14"/16";
  measure from a photo: `notchWidth ≈ overlayCSSWidth × notchPx / overlayPx`).
- Content (icons/status) goes in the **wings beside the notch**, vertically
  centered on the band (height = `inset`); the camera center stays empty.
- Concave top "ears" so edges blend into the screen edge — CSS inverse corner:

```css
.ear-l { position:absolute; top:0; left:-10px; width:10px; height:10px;
  background: radial-gradient(circle 10px at 0 10px, transparent 9.5px, #000 10px); }
/* mirror for .ear-r with `at 10px 10px` */
```

- Spring feel: `transition: width .34s cubic-bezier(0.34, 1.2, 0.64, 1)`.

## Interaction contract (don't skip)

- Idle = `setIgnoreMouseEvents(true, {forward:true})`; renderer detects hover
  from forwarded `mousemove` and asks main to flip interactivity.
- **Collapse must be main-process-driven**: poll `screen.getCursorScreenPoint()`
  vs window bounds while interactive (~250ms) and notify the renderer when the
  cursor leaves. Renderer-only `mouseleave` gets stuck open.
- No click-anywhere-to-pin: silent pinning reads as "it won't close".

## Common mistakes

| Mistake | Consequence |
|---|---|
| `y: workArea.y` or hardcoded 24/33/38px | gap or seam on scaled resolutions |
| Negative CSS margins to "move up" | content invisible behind the physical notch |
| Omitting `enableLargerThanScreen` | clamped to menu-bar bottom; wrongly concluding "impossible in Electron" |
| Trusting requested `y` | AppKit may shift it — always read back `getBounds()` |
| Semi-transparent dark background | never blends with the notch — must be `#000` |
| Hover zone = a thin visible element only | make an invisible ≥24px strip; hairlines can't be pointed at |
