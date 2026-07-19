import { app, BrowserWindow, ipcMain, shell, systemPreferences } from "electron";
import { existsSync, writeFileSync } from "node:fs";
import { join } from "node:path";

/** First-run marker: onboarding shows once, then never again. */
function flagPath(): string {
  return join(app.getPath("userData"), "onboarded");
}

let win: BrowserWindow | null = null;
let trustPoll: ReturnType<typeof setInterval> | null = null;

function onboardingState() {
  return {
    accessibilityTrusted: systemPreferences.isTrustedAccessibilityClient(false),
    openAtLogin: app.getLoginItemSettings().openAtLogin,
  };
}

export function registerOnboardingIpc(): void {
  ipcMain.handle("agent-island:onboarding-state", () => onboardingState());

  ipcMain.on("agent-island:enable-accessibility", () => {
    // Prompts macOS to add us to the Accessibility list, and opens the pane so
    // the user can flip the switch. The poll below reflects it live.
    systemPreferences.isTrustedAccessibilityClient(true);
    void shell.openExternal(
      "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
    );
  });

  ipcMain.on("agent-island:set-login", (_e, on: boolean) => {
    app.setLoginItemSettings({ openAtLogin: on, openAsHidden: true });
    pushState();
  });

  ipcMain.on("agent-island:finish-onboarding", () => {
    try {
      writeFileSync(flagPath(), new Date().toISOString());
    } catch {
      /* worst case: onboarding shows again next launch */
    }
    win?.close();
  });
}

function pushState(): void {
  if (win && !win.isDestroyed()) {
    win.webContents.send("agent-island:onboarding-state", onboardingState());
  }
}

/** Show the onboarding window on first launch only. */
export function maybeShowOnboarding(): void {
  if (existsSync(flagPath())) return;

  win = new BrowserWindow({
    width: 640,
    height: 520,
    show: false,
    frame: false,
    transparent: true,
    backgroundColor: "#00000000",
    resizable: false,
    maximizable: false,
    minimizable: false,
    fullscreenable: false,
    skipTaskbar: false,
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
    void win.loadURL(`${process.env.ELECTRON_RENDERER_URL}/onboarding.html`);
  } else {
    void win.loadFile(join(__dirname, "../renderer/onboarding.html"));
  }

  win.once("ready-to-show", () => {
    win?.show();
    win?.focus();
  });

  // Reflect the Accessibility toggle live while the window is open.
  trustPoll = setInterval(pushState, 1200);
  win.on("closed", () => {
    if (trustPoll) clearInterval(trustPoll);
    trustPoll = null;
    win = null;
  });
}
