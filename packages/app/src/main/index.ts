import {
  app,
  BrowserWindow,
  dialog,
  globalShortcut,
  ipcMain,
  powerMonitor,
  screen,
  shell,
  type Tray,
} from "electron";
import { copyFileSync, existsSync, mkdirSync, readFileSync, rmSync } from "node:fs";
import { basename, extname, join } from "node:path";
import type { AgentUsage, ApprovalDecision, SessionSnapshot } from "@agent-island/shared";
import { DaemonClient } from "./daemon-client";
import { ensureDaemon, stopDaemon } from "./daemon-manager";
import {
  removeClaudeHooks,
  removeCursorHooks,
  setupCursorZeroConfig,
  setupZeroConfig,
} from "./zero-config";
import { createNotchWindow } from "./windows/notch-window";
import { maybeShowOnboarding, registerOnboardingIpc } from "./windows/onboarding-window";
import { pushSettingsState, showSettingsWindow } from "./windows/settings-window";
import {
  isSoundEvent,
  isSoundTheme,
  isOpenWith,
  isTemperatureUnit,
  isTextSize,
  loadSettings,
  saveSettings,
} from "./settings";
import {
  haptic,
  hapticsSupported,
  isHapticPattern,
  setHapticsEnabled,
  setHapticsQuiet,
} from "./haptics";
import { getPower, onPower, setPowerEnabled, startPower } from "./power";
import { setProcStatsActive, setProcStatsEnabled, startProcStats } from "./proc-stats";
import { clearFocus, getFocus, onFocus, setFocus } from "./focus";
import { DEEP_LINK_SCHEME, focusLinks, parseDeepLink } from "./deep-link";
import { stopHelper } from "./native-helper";
import { readNaturalScroll } from "./scroll-direction";
import {
  glassSupport,
  glassTier,
  hideGlass,
  initGlass,
  onGlassSupport,
  setGlassEnabled,
  setGlassMediaPrefs,
  updateGlass,
} from "./glass";
import { getWeather, onWeather, startWeather, updateWeatherSettings } from "./weather";
import { createTray, updateTrayTitle } from "./tray";
import { answerInTerminal, jumpToTerminal, sendPromptToTerminal } from "./jump-back";
import {
  checkNow,
  downloadAndInstall,
  getPendingUpdate,
  openUpdatePage,
  startUpdateCheck,
  stopUpdateCheck,
} from "./update-check";

// One instance only — two overlays fighting over the notch would be chaos.
if (!app.requestSingleInstanceLock()) {
  app.quit();
} else {
  // Memory: drop the GPU process — macOS software-composites the transparent
  // overlay fine — and cap V8 heap growth across the app.
  app.disableHardwareAcceleration();
  app.commandLine.appendSwitch("js-flags", "--max-old-space-size=96");

  let notch: BrowserWindow | null = null;
  let tray: Tray | null = null;
  const daemon = new DaemonClient();

  // During quit the window object outlives its native counterpart; sending to a
  // destroyed webContents throws "Object has been destroyed". The isDestroyed
  // check races with teardown — an interval that fires mid-quit can pass it and
  // still throw from inside send — so the guard is belt and braces.
  function sendToNotch(channel: string, ...args: unknown[]): void {
    if (!notch || notch.isDestroyed()) return;
    try {
      notch.webContents.send(channel, ...args);
    } catch {
      /* window went away between the check and the send */
    }
  }

  // ⌘Y / ⌘N resolve a pending approval. The notch window is non-focusable, so we
  // use global shortcuts — registered only while an approval is actually pending.
  let pendingApprovalId: string | null = null;
  function syncApprovalShortcuts(sessions: SessionSnapshot[]): void {
    const id = sessions.find((s) => s.pending_approval)?.pending_approval?.id ?? null;
    if (id === pendingApprovalId) return;
    pendingApprovalId = id;
    globalShortcut.unregister("CommandOrControl+Y");
    globalShortcut.unregister("CommandOrControl+N");
    if (id) {
      globalShortcut.register("CommandOrControl+Y", () => {
        if (!pendingApprovalId) return;
        sendToNotch("agent-island:chime", "approve");
        haptic("commit");
        void daemon.resolveApproval(pendingApprovalId, "allow");
      });
      globalShortcut.register("CommandOrControl+N", () => {
        if (!pendingApprovalId) return;
        // Denying is silent by design, but it still deserves confirmation that
        // the keystroke landed — that's exactly what a single tap is for.
        haptic("commit");
        void daemon.resolveApproval(pendingApprovalId, "deny");
      });
    }
  }

  // Claude questions are answered through the daemon's held hook — no terminal
  // focus or synthetic keystrokes needed. Codex (and an expired hold) falls
  // back to jump + keystrokes (single-question only; multi just jumps).
  async function answerQuestion(session: SessionSnapshot, options: number[]): Promise<void> {
    const q = session.pending_question;
    if (q && session.agent === "claude-code" && (await daemon.answerQuestion(q.id, options))) {
      console.log(`[jump] answered ${q.id} via hook (${options.join(",")})`);
      sendToNotch("agent-island:chime", "approve");
      return;
    }
    if (options.length === 1) answerInTerminal(session, String(options[0] + 1));
    else jumpToTerminal(session);
  }

  // While an agent waits on a single multiple-choice question, ⌘1..⌘9 answer
  // it from anywhere (registered only for the shown options, released the
  // moment the question clears — same transient pattern as ⌘Y/⌘N approvals).
  // Multi-question cards are answered by clicking each choice on the island.
  let questionId: string | null = null;
  let questionKeyCount = 0;
  function syncQuestionShortcuts(sessions: SessionSnapshot[]): void {
    const session = sessions.find((s) => s.pending_question);
    const q = session?.pending_question ?? null;
    if ((q?.id ?? null) === questionId) return;
    for (let i = 1; i <= questionKeyCount; i++) {
      globalShortcut.unregister(`CommandOrControl+${i}`);
    }
    questionId = q?.id ?? null;
    questionKeyCount = 0;
    if (!session || !q || q.questions.length !== 1) return;
    questionKeyCount = Math.min(9, q.questions[0].options.length);
    for (let i = 1; i <= questionKeyCount; i++) {
      globalShortcut.register(`CommandOrControl+${i}`, () => void answerQuestion(session, [i - 1]));
    }
  }

  /**
   * VoiceOver reach-in. The overlay is created non-focusable so it never steals
   * focus from your terminal — but a non-focusable NSPanel is effectively
   * invisible to VoiceOver, and no amount of ARIA fixes that. This shortcut
   * flips focusable on, focuses the window, and puts the renderer into a focus
   * trap; pressing it again (or Escape in the renderer) hands focus back.
   *
   * Four modifiers on purpose: ⌥⌘I is the browser devtools shortcut, and a
   * global registration would shadow it for exactly this app's audience.
   */
  const A11Y_FOCUS_SHORTCUT = "Control+Alt+Command+I";
  let a11yShortcutRegistered = false;
  let a11yFocused = false;

  function setA11yFocus(on: boolean): void {
    if (!notch || notch.isDestroyed() || a11yFocused === on) return;
    a11yFocused = on;
    notch.setFocusable(on);
    if (on) notch.focus();
    sendToNotch("agent-island:a11y-focus", on);
    console.log(`[a11y] island focus=${on}`);
  }

  /** Latest island rectangle in window coordinates, reported by the renderer. */
  let islandRect: { x: number; y: number; width: number; height: number } | null = null;

  // agent-island:// deep links. Focus can't be read (Full Disk Access, no
  // public API), so a Shortcuts automation opens focus/on|off when it changes;
  // toggle and settings come along for free. Registered before `ready` so a
  // link that LAUNCHES the app is delivered too.
  function handleDeepLink(url: string): void {
    const link = parseDeepLink(url);
    if (!link) {
      console.log(`[deep-link] ignored ${url}`);
      return;
    }
    console.log(`[deep-link] ${url}`);
    if (link.kind === "focus") setFocus(link.active, link.name);
    else if (link.kind === "toggle") sendToNotch("agent-island:toggle");
    else showSettingsWindow();
  }
  app.on("open-url", (event, url) => {
    event.preventDefault();
    handleDeepLink(url);
  });

  app.whenReady().then(async () => {
    app.dock?.hide(); // menu-bar app, no Dock icon
    notch = createNotchWindow();
    initGlass(notch);

    // Battery saver: freeze the overlay's animations while the Mac is locked or
    // asleep — a long agent run shouldn't keep compositing the notch when nobody
    // can see it. Resume the moment the screen comes back.
    const setAnimating = (active: boolean) => sendToNotch("agent-island:animation-active", active);
    powerMonitor.on("lock-screen", () => {
      setAnimating(false);
      hideGlass();
    });
    powerMonitor.on("suspend", () => {
      setAnimating(false);
      hideGlass();
    });
    powerMonitor.on("unlock-screen", () => setAnimating(true));
    powerMonitor.on("resume", () => setAnimating(true));

    const settings = loadSettings();
    setHapticsEnabled(settings.haptics);
    setGlassEnabled(settings.glass);

    // Only a packaged app should own the scheme system-wide; a dev Electron
    // binary registering itself as a URL handler would be a mess to undo.
    let deepLinksRegistered = false;
    if (app.isPackaged) {
      deepLinksRegistered = app.setAsDefaultProtocolClient(DEEP_LINK_SCHEME);
      if (!deepLinksRegistered) console.warn(`[deep-link] could not register ${DEEP_LINK_SCHEME}://`);
    } else {
      console.log(`[deep-link] dev build: ${DEEP_LINK_SCHEME}:// is not registered`);
    }

    // Focus: while it's on (and the setting says so) sounds and notification
    // haptics go quiet. Visual pulses and auto-expand are untouched — a blocked
    // agent must still be seen.
    const focusMuted = () => settings.respectFocus && getFocus().active;
    const focusPayload = () => ({ ...getFocus(), mute: focusMuted() });
    const applyFocusEffects = () => {
      setHapticsQuiet(focusMuted());
      sendToNotch("agent-island:focus", focusPayload());
    };
    onFocus(() => {
      applyFocusEffects();
      pushSettingsState(settingsState());
    });

    // Natural scrolling inverts what a swipe looks like to the renderer; read
    // it once so gestures are defined by finger motion, not wheel sign.
    let naturalScroll = true;
    void readNaturalScroll().then((natural) => {
      naturalScroll = natural;
      sendToNotch("agent-island:ui-prefs", uiPrefs());
    });

    // Disabled integrations disappear everywhere the UI looks.
    const filterSessions = (sessions: SessionSnapshot[]): SessionSnapshot[] =>
      sessions.filter((s) => settings.agents[s.agent] !== false);
    const filterUsage = (usage: AgentUsage[]): AgentUsage[] =>
      usage.filter((u) => settings.agents[u.agent] !== false);

    // Menu-bar icon: a setting now (AGENT_ISLAND_TRAY=1 still forces it on).
    function syncTray(): void {
      const want = settings.tray || process.env.AGENT_ISLAND_TRAY === "1";
      if (want && !tray) {
        tray = createTray({
          onToggle: () => sendToNotch("agent-island:toggle"),
          onQuit: () => app.quit(),
          isSoundOn: () => settings.sounds,
          onToggleSound: (on) => applySetting("sounds", on),
        });
      } else if (!want && tray) {
        tray.destroy();
        tray = null;
      }
    }
    syncTray();

    const onUpdateInfo = (info: { version: string }): void =>
      sendToNotch("agent-island:update", info);

    const AUDIO_MIME: Record<string, string> = {
      ".mp3": "audio/mpeg",
      ".wav": "audio/wav",
      ".m4a": "audio/mp4",
      ".aac": "audio/aac",
      ".ogg": "audio/ogg",
      ".oga": "audio/ogg",
      ".aif": "audio/aiff",
      ".aiff": "audio/aiff",
      ".flac": "audio/flac",
    };
    /** Read each imported sound file into a data URL (the renderer is sandboxed
     *  and can't read arbitrary FS paths). Skips missing/unreadable files. */
    function customSoundData(): Record<string, string> {
      const out: Record<string, string> = {};
      for (const [event, path] of Object.entries(settings.customSounds)) {
        if (typeof path !== "string" || !existsSync(path)) continue;
        try {
          const mime = AUDIO_MIME[extname(path).toLowerCase()] ?? "audio/mpeg";
          out[event] = `data:${mime};base64,${readFileSync(path).toString("base64")}`;
        } catch {
          /* unreadable -> skip; the event falls back to its theme */
        }
      }
      return out;
    }

    function settingsState() {
      return {
        ...settings,
        customSounds: customSoundData(),
        openAtLogin: app.getLoginItemSettings().openAtLogin,
        version: app.getVersion(),
        update: getPendingUpdate(),
        // So Settings can explain why the haptics toggle may do nothing.
        hapticsSupported: hapticsSupported(),
        // So Settings can say whether the glass toggle can bite, and how.
        glassSupport: glassSupport(),
        focus: getFocus(),
        focusLinks: focusLinks(),
        deepLinksRegistered,
        a11yShortcut: a11yShortcutRegistered ? A11Y_FOCUS_SHORTCUT : null,
      };
    }

    /** Presentation prefs the overlay itself needs (text scale, open gesture). */
    const uiPrefs = () => ({
      textSize: settings.textSize,
      openWith: settings.openWith,
      naturalScroll,
      // Which material the renderer should style for: native/vibrancy = a
      // real glass panel sits beneath; css = draw the panel itself.
      glass: glassTier(),
    });

    // The sidecar answers `glass caps` asynchronously; refresh both windows.
    onGlassSupport(() => {
      sendToNotch("agent-island:ui-prefs", uiPrefs());
      pushSettingsState(settingsState());
    });

    const weatherOptions = () => ({
      enabled: settings.weather,
      units: settings.weatherUnits,
      location: settings.weatherLocation,
    });
    const applyWeatherSettings = (): void => updateWeatherSettings(weatherOptions());

    function pushFiltered(): void {
      sendToNotch("agent-island:sessions", {
        sessions: filterSessions(daemon.list()),
        connected: daemon.isConnected(),
      });
      sendToNotch("agent-island:usage", filterUsage(daemon.getUsage()));
    }

    const soundPrefs = () => ({
      on: settings.sounds,
      theme: settings.soundTheme,
      overrides: settings.soundOverrides,
      custom: customSoundData(),
    });

    /** The one place a setting changes: persist, apply side effects, broadcast. */
    function applySetting(key: string, value: boolean | string): void {
      switch (key) {
        case "agent:claude-code":
          settings.agents["claude-code"] = value === true;
          if (value) setupZeroConfig();
          else removeClaudeHooks();
          break;
        case "agent:codex":
          settings.agents.codex = value === true; // read-only tailer; hiding it is disconnecting
          break;
        case "agent:cursor":
          settings.agents.cursor = value === true;
          if (value) setupCursorZeroConfig();
          else removeCursorHooks();
          break;
        case "sounds":
          settings.sounds = value === true;
          sendToNotch("agent-island:sounds", soundPrefs());
          break;
        case "soundTheme":
          if (!isSoundTheme(value)) return;
          settings.soundTheme = value;
          // A theme switch is a fresh start: per-event overrides reset so
          // every row follows the newly picked theme.
          settings.soundOverrides = {};
          sendToNotch("agent-island:sounds", soundPrefs());
          break;
        case "haptics":
          settings.haptics = value === true;
          setHapticsEnabled(settings.haptics);
          // Confirm the change through the sense being changed.
          if (settings.haptics) haptic("commit");
          break;
        case "textSize":
          if (!isTextSize(value)) return;
          settings.textSize = value;
          sendToNotch("agent-island:ui-prefs", uiPrefs());
          break;
        case "openWith":
          if (!isOpenWith(value)) return;
          settings.openWith = value;
          sendToNotch("agent-island:ui-prefs", uiPrefs());
          break;
        case "glass":
          settings.glass = value === true;
          setGlassEnabled(settings.glass);
          sendToNotch("agent-island:ui-prefs", uiPrefs());
          break;
        case "battery":
          settings.battery = value === true;
          setPowerEnabled(settings.battery);
          break;
        case "procStats":
          settings.procStats = value === true;
          setProcStatsEnabled(settings.procStats);
          break;
        case "respectFocus":
          settings.respectFocus = value === true;
          applyFocusEffects();
          break;
        case "weather":
          settings.weather = value === true;
          applyWeatherSettings();
          break;
        case "weatherLocation":
          if (typeof value !== "string") return;
          settings.weatherLocation = value;
          applyWeatherSettings();
          break;
        case "weatherUnits":
          if (!isTemperatureUnit(value)) return;
          settings.weatherUnits = value;
          applyWeatherSettings();
          break;
        case "tray":
          settings.tray = value === true;
          syncTray();
          break;
        case "updateCheck":
          settings.updateCheck = value === true;
          if (value) startUpdateCheck(onUpdateInfo);
          else stopUpdateCheck();
          break;
        case "openAtLogin":
          app.setLoginItemSettings({ openAtLogin: value === true, openAsHidden: true });
          break;
        default: {
          // "soundOverride:<event>" — value is a theme, or "" for theme-default.
          const event = key.startsWith("soundOverride:") ? key.slice(14) : null;
          if (!isSoundEvent(event)) return;
          if (isSoundTheme(value)) settings.soundOverrides[event] = value;
          else delete settings.soundOverrides[event];
          sendToNotch("agent-island:sounds", soundPrefs());
          break;
        }
      }
      saveSettings(settings);
      pushSettingsState(settingsState());
      pushFiltered();
    }

    a11yShortcutRegistered = globalShortcut.register(A11Y_FOCUS_SHORTCUT, () =>
      setA11yFocus(!a11yFocused),
    );
    if (!a11yShortcutRegistered) {
      console.warn(`[a11y] could not register ${A11Y_FOCUS_SHORTCUT} — another app holds it`);
    }
    // Escape inside the trap hands focus back to whatever had it.
    ipcMain.on("agent-island:a11y-release", () => setA11yFocus(false));

    ipcMain.handle("agent-island:get-ui-prefs", () => uiPrefs());
    ipcMain.handle("agent-island:get-weather", () => getWeather());

    // Weather changes are ambient, so they get the subtlest tap available —
    // never anything that could be mistaken for an agent needing you. Thunder
    // arriving is the one exception worth feeling.
    onWeather((state) => {
      sendToNotch("agent-island:weather", state);
      if (!state || state.stale) return;
      haptic(state.condition === "thunder" ? "rumble" : "whisper");
    });
    startWeather(weatherOptions());

    // Battery: instant plug/unplug from powerMonitor, percentage from pmset.
    onPower((payload) => sendToNotch("agent-island:power", payload));
    startPower(settings.battery);
    ipcMain.handle("agent-island:get-power", () => getPower());

    // Focus, via deep links (see handleDeepLink).
    ipcMain.handle("agent-island:get-focus", () => focusPayload());
    ipcMain.on("agent-island:clear-focus", () => clearFocus());
    ipcMain.on("agent-island:open-shortcuts", () => void shell.openExternal("shortcuts://"));

    // Resource meter: one `ps` every 2s while the panel is open, summed over
    // each session's process tree from the PID its hook bridge reported.
    startProcStats({
      enabled: settings.procStats,
      roots: () => {
        const roots = new Map<string, number>();
        for (const s of filterSessions(daemon.list())) {
          const pid = Number(s.meta?.pid);
          if (Number.isInteger(pid) && pid > 0) roots.set(s.key, pid);
        }
        return roots;
      },
      onStats: (stats) => sendToNotch("agent-island:proc-stats", stats),
    });

    // Renderer-initiated haptics (row clicks, control presses). Guarded because
    // this crosses the contextBridge.
    ipcMain.on("agent-island:haptic", (_e, pattern: unknown) => {
      if (isHapticPattern(pattern)) haptic(pattern);
    });

    // The island is much narrower than its window, so the renderer reports
    // where it actually is; see the cursor watcher below.
    ipcMain.on(
      "agent-island:island-rect",
      (
        _e,
        rect: { x: number; y: number; width: number; height: number },
        panel: { x: number; y: number; width: number; height: number } | null,
      ) => {
        islandRect = rect;
        // The glass sheet follows the panel portion, frame by frame.
        if (notch && !notch.isDestroyed()) updateGlass(notch.getBounds(), panel ?? null);
      },
    );

    // Reduce transparency / Increase contrast: the renderer already honours
    // both in CSS; here they also retire the native glass the moment they flip.
    ipcMain.on(
      "agent-island:media-prefs",
      (_e, prefs: { reducedTransparency?: boolean; moreContrast?: boolean } | null) => {
        setGlassMediaPrefs({
          reducedTransparency: prefs?.reducedTransparency === true,
          moreContrast: prefs?.moreContrast === true,
        });
        sendToNotch("agent-island:ui-prefs", uiPrefs());
      },
    );

    ipcMain.handle("agent-island:get-sounds", () => soundPrefs());
    ipcMain.on("agent-island:set-sounds", (_e, on: boolean) => applySetting("sounds", on));

    // Import a user's own audio file for one event: copy it into userData/sounds,
    // remember the path, and broadcast the new data URLs to the notch + settings.
    ipcMain.handle("agent-island:import-sound", async (_e, event: string) => {
      if (!isSoundEvent(event)) return false;
      const res = await dialog.showOpenDialog({
        title: "Choose a sound",
        properties: ["openFile"],
        filters: [
          { name: "Audio", extensions: ["mp3", "wav", "m4a", "aac", "ogg", "oga", "aif", "aiff", "flac"] },
        ],
      });
      if (res.canceled || res.filePaths.length === 0) return false;
      const src = res.filePaths[0];
      const dir = join(app.getPath("userData"), "sounds");
      const dest = join(dir, `${event}${extname(src).toLowerCase() || ".mp3"}`);
      const prev = settings.customSounds[event];
      try {
        mkdirSync(dir, { recursive: true });
        // A new extension would orphan the old file — remove it first.
        if (typeof prev === "string" && prev !== dest && existsSync(prev)) rmSync(prev);
        copyFileSync(src, dest);
      } catch (err) {
        console.error("[sound] import failed:", err);
        return false;
      }
      settings.customSounds[event] = dest;
      settings.customSoundNames[event] = basename(src);
      saveSettings(settings);
      sendToNotch("agent-island:sounds", soundPrefs());
      pushSettingsState(settingsState());
      return true;
    });

    ipcMain.on("agent-island:clear-sound", (_e, event: string) => {
      if (!isSoundEvent(event)) return;
      const prev = settings.customSounds[event];
      if (typeof prev === "string" && existsSync(prev)) {
        try {
          rmSync(prev);
        } catch {
          /* best-effort cleanup */
        }
      }
      delete settings.customSounds[event];
      delete settings.customSoundNames[event];
      saveSettings(settings);
      sendToNotch("agent-island:sounds", soundPrefs());
      pushSettingsState(settingsState());
    });
    ipcMain.handle("agent-island:get-settings", () => settingsState());
    // Settings "Check for updates" — run a check now and push the result back.
    ipcMain.handle("agent-island:check-updates", async () => {
      await checkNow(onUpdateInfo);
      pushSettingsState(settingsState());
      return getPendingUpdate();
    });
    // Settings "Install & Restart" — download the DMG and self-replace.
    ipcMain.handle("agent-island:install-update", () => downloadAndInstall());
    ipcMain.on("agent-island:set-setting", (_e, { key, value }: { key: string; value: boolean | string }) =>
      applySetting(key, value),
    );
    ipcMain.on("agent-island:open-settings", () => showSettingsWindow());

    // Traffic lights in frameless windows: act on whichever window asked.
    ipcMain.on("agent-island:win-close", (e) => BrowserWindow.fromWebContents(e.sender)?.close());
    ipcMain.on("agent-island:win-minimize", (e) =>
      BrowserWindow.fromWebContents(e.sender)?.minimize(),
    );

    // First launch: a short onboarding (island tour + Accessibility + login).
    registerOnboardingIpc();
    maybeShowOnboarding();

    // Update NOTIFIER (no self-update without a Developer ID): one anonymous
    // check against GitHub Releases; the island shows a chip, a notification
    // links to the download. Toggle in Settings; AGENT_ISLAND_NO_UPDATE_CHECK=1
    // still disables outright.
    if (settings.updateCheck) startUpdateCheck(onUpdateInfo);
    ipcMain.on("agent-island:open-update", () => openUpdatePage());

    // Zero Config: wire enabled agents to the daemon (token + safe hook
    // merges; Codex needs nothing — its rollout logs are tailed directly).
    if (settings.agents["claude-code"]) setupZeroConfig();
    if (settings.agents.cursor) setupCursorZeroConfig();

    // One launch runs everything: spawn the daemon if it isn't already up.
    await ensureDaemon();

    daemon.onSessions((sessions: SessionSnapshot[], connected: boolean) => {
      const visible = filterSessions(sessions);
      sendToNotch("agent-island:sessions", { sessions: visible, connected });
      if (tray && !tray.isDestroyed()) updateTrayTitle(tray, visible);
      syncApprovalShortcuts(visible);
      syncQuestionShortcuts(visible);
    });
    daemon.onUsage((usage) => sendToNotch("agent-island:usage", filterUsage(usage)));
    daemon.start();

    // Renderer pulls initial state on mount (it may load after the first push).
    ipcMain.handle("agent-island:get-sessions", () => ({
      sessions: filterSessions(daemon.list()),
      connected: daemon.isConnected(),
    }));
    ipcMain.handle("agent-island:get-usage", () => filterUsage(daemon.getUsage()));

    // Renderer toggles click-through as the pointer enters/leaves the pill.
    // While interactive, poll the real cursor so the island reliably collapses
    // the moment the pointer leaves the window (renderer-side mouse events
    // alone proved flaky and left it stuck open).
    let cursorWatch: ReturnType<typeof setInterval> | null = null;
    ipcMain.on("agent-island:set-interactive", (_e, interactive: boolean) => {
      console.log(`[notch] interactive=${interactive}`);
      if (notch && !notch.isDestroyed()) notch.setIgnoreMouseEvents(!interactive, { forward: true });
      // The meter samples only while someone can see it.
      setProcStatsActive(interactive);
      if (cursorWatch) {
        clearInterval(cursorWatch);
        cursorWatch = null;
      }
      if (interactive) {
        cursorWatch = setInterval(() => {
          if (!notch || notch.isDestroyed()) return;
          // While VoiceOver holds the island open the pointer is irrelevant —
          // and is almost certainly nowhere near it.
          if (a11yFocused) return;
          const p = screen.getCursorScreenPoint();
          const b = notch.getBounds();
          // Test the ISLAND, not the window: the window is deliberately far
          // wider than the visible pill (room for the expanded panel), so
          // window bounds would keep the island open with the pointer a couple
          // of hundred px away from anything drawn.
          const r = islandRect
            ? {
                x: b.x + islandRect.x,
                y: b.y + islandRect.y,
                width: islandRect.width,
                height: islandRect.height,
              }
            : b;
          const margin = 10;
          const inside =
            p.x >= r.x - margin &&
            p.x <= r.x + r.width + margin &&
            p.y >= r.y - margin &&
            p.y <= r.y + r.height + margin;
          if (!inside) sendToNotch("agent-island:cursor-left");
        }, 250);
      }
    });

    ipcMain.on("agent-island:jump", (_e, session: SessionSnapshot) => {
      console.log(`[jump] requested for ${session.key}`);
      jumpToTerminal(session);
    });

    ipcMain.on(
      "agent-island:answer",
      (_e, { session, options }: { session: SessionSnapshot; options: number[] }) => {
        console.log(`[jump] answer [${options.join(",")}] for ${session.key}`);
        void answerQuestion(session, options);
      },
    );

    ipcMain.on(
      "agent-island:send-prompt",
      (_e, { session, text }: { session: SessionSnapshot; text: string }) => {
        console.log(`[jump] send-prompt for ${session.key}`);
        const result = sendPromptToTerminal(session, text);
        // Tell the notch so it can show a hint instead of failing silently.
        sendToNotch("agent-island:prompt-status", result);
      },
    );

    // The overlay is created non-focusable so it never steals focus from the
    // terminal — but a non-focusable window can't become key, so keystrokes
    // never reach the prompt input. Flip focusable on only while composing.
    ipcMain.on("agent-island:prompt-composing", (_e, active: boolean) => {
      if (!notch || notch.isDestroyed()) return;
      console.log(`[notch] prompt-composing=${active}`);
      // Blurring the prompt must not yank focusability out from under an active
      // VoiceOver session, which holds it for its own reasons.
      notch.setFocusable(active || a11yFocused);
      if (active) notch.focus();
    });

    ipcMain.on(
      "agent-island:approve",
      (_e, { id, decision }: { id: string; decision: ApprovalDecision }) => {
        if (decision === "allow") sendToNotch("agent-island:chime", "approve");
        haptic("commit");
        void daemon.resolveApproval(id, decision);
      },
    );

    ipcMain.on("agent-island:quit", () => app.quit());
  });

  // Keep running with no windows — this is a menu-bar/overlay app.
  app.on("window-all-closed", () => {
    /* stay alive */
  });

  app.on("before-quit", () => {
    globalShortcut.unregisterAll();
    stopUpdateCheck();
    stopHelper();
    // Remove our hooks before we go: the HTTP hooks point at the daemon we're
    // about to stop, so leaving them behind makes every subsequent Claude/Cursor
    // tool call error against a dead port. They're re-installed on next launch.
    removeClaudeHooks();
    removeCursorHooks();
    daemon.stop();
    stopDaemon();
  });
}
