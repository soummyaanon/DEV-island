import { app, Menu, Tray, nativeImage } from "electron";
import type { SessionSnapshot } from "@agent-island/shared";

export interface TrayCallbacks {
  onToggle: () => void;
  onQuit: () => void;
  isSoundOn: () => boolean;
  onToggleSound: (on: boolean) => void;
}

function buildMenu(tray: Tray, cb: TrayCallbacks): void {
  const openAtLogin = app.getLoginItemSettings().openAtLogin;
  const menu = Menu.buildFromTemplate([
    { label: "Agent Island", enabled: false },
    { type: "separator" },
    { label: "Toggle Island", click: cb.onToggle },
    {
      label: "Sound Effects",
      type: "checkbox",
      checked: cb.isSoundOn(),
      click: (item) => {
        cb.onToggleSound(item.checked);
        buildMenu(tray, cb);
      },
    },
    {
      label: "Open at Login",
      type: "checkbox",
      checked: openAtLogin,
      click: (item) => {
        app.setLoginItemSettings({ openAtLogin: item.checked, openAsHidden: true });
        buildMenu(tray, cb); // refresh checkbox state
      },
    },
    { type: "separator" },
    { label: "Quit Agent Island", click: cb.onQuit },
  ]);
  tray.setContextMenu(menu);
}

/**
 * Menu-bar presence. Empty image + emoji title so the app has a home (and Quit)
 * without shipping icon assets yet. The title doubles as at-a-glance status.
 */
export function createTray(cb: TrayCallbacks): Tray {
  const tray = new Tray(nativeImage.createEmpty());
  tray.setTitle(" 🏝");
  buildMenu(tray, cb);
  return tray;
}

export function updateTrayTitle(tray: Tray, sessions: SessionSnapshot[]): void {
  const attention = sessions.filter((s) => s.requires_action).length;
  const active = sessions.filter((s) => s.state === "working" || s.state === "starting").length;

  if (attention > 0) tray.setTitle(` 🏝 ⚠ ${attention}`);
  else if (active > 0) tray.setTitle(` 🏝 ${active}`);
  else tray.setTitle(" 🏝");
}
