import type { Input, WebContents } from "electron";

/**
 * ⌘V / ⌘C / ⌘X / ⌘A / ⌘Z for every text field we own.
 *
 * On macOS these are menu key equivalents, and AppKit only routes them
 * through the menu of the ACTIVE app. The island is an accessory app that
 * types into a window without ever becoming active, so the Edit menu alone
 * never sees the keystroke and only Ctrl+V (which Chromium handles itself)
 * got through. Handling them on the web contents works whether or not we
 * are frontmost; the event is consumed so an active menu can't double-fire.
 */

export type EditCommand = "paste" | "pasteAndMatchStyle" | "copy" | "cut" | "selectAll" | "undo" | "redo";

export function editCommandFor(input: Pick<Input, "type" | "key" | "meta" | "control" | "alt" | "shift">): EditCommand | null {
  if (input.type !== "keyDown" || !input.meta || input.control || input.alt) return null;
  switch (input.key.toLowerCase()) {
    case "v":
      return input.shift ? "pasteAndMatchStyle" : "paste";
    case "c":
      return input.shift ? null : "copy";
    case "x":
      return input.shift ? null : "cut";
    case "a":
      return input.shift ? null : "selectAll";
    case "z":
      return input.shift ? "redo" : "undo";
    default:
      return null;
  }
}

export function attachEditShortcuts(contents: WebContents): void {
  if (process.platform !== "darwin") return;
  contents.on("before-input-event", (event, input) => {
    const command = editCommandFor(input);
    if (!command) return;
    event.preventDefault();
    contents[command]();
  });
}
