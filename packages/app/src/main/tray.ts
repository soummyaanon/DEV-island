import { Menu, Tray, nativeImage } from "electron";
import type { SessionSnapshot } from "@agent-island/shared";

/**
 * Menu-bar presence. We use an empty image + an emoji title so the app has a
 * home (and a Quit) without shipping icon assets in this first slice. The title
 * doubles as an at-a-glance status: active count, or ⚠ when something waits.
 */
export function createTray(onToggle: () => void, onQuit: () => void): Tray {
  const tray = new Tray(nativeImage.createEmpty());
  tray.setTitle(" 🏝");

  const menu = Menu.buildFromTemplate([
    { label: "Agent Island", enabled: false },
    { type: "separator" },
    { label: "Toggle Island", click: onToggle },
    { label: "Quit Agent Island", click: onQuit },
  ]);
  tray.setContextMenu(menu);
  return tray;
}

export function updateTrayTitle(tray: Tray, sessions: SessionSnapshot[]): void {
  const attention = sessions.filter((s) => s.requires_action).length;
  const active = sessions.filter((s) => s.state === "working" || s.state === "starting").length;

  if (attention > 0) tray.setTitle(` 🏝 ⚠ ${attention}`);
  else if (active > 0) tray.setTitle(` 🏝 ${active}`);
  else tray.setTitle(" 🏝");
}
