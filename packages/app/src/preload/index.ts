import { contextBridge, ipcRenderer } from "electron";
import type { AgentKind, AgentUsage, ApprovalDecision, SessionSnapshot } from "@agent-island/shared";

export interface SoundPrefsPayload {
  on: boolean;
  theme: string;
  overrides: Record<string, string>;
  /** Per-event imported audio as data URLs (event -> "data:audio/...;base64,..."). */
  custom: Record<string, string>;
}

export interface SettingsState {
  agents: Record<AgentKind, boolean>;
  sounds: boolean;
  soundTheme: string;
  soundOverrides: Record<string, string>;
  /** Per-event imported audio as data URLs (event -> data URL), for preview/display. */
  customSounds: Record<string, string>;
  /** Original file names of the imports (event -> "goku-punch.mp3"). */
  customSoundNames: Record<string, string>;
  tray: boolean;
  updateCheck: boolean;
  haptics: boolean;
  textSize: string;
  /** False when the native helper is absent — the haptics toggle can't bite. */
  hapticsSupported: boolean;
  /** The registered VoiceOver focus shortcut, or null if another app holds it. */
  a11yShortcut: string | null;
  weather: boolean;
  weatherLocation: string;
  weatherUnits: string;
  /** "hover" | "swipe" — how the collapsed island opens. */
  openWith: string;
  /** "compact" | "detailed" — session bubbles or full rows. */
  sessionView: string;
  /** Liquid Glass under the expanded panel. */
  glass: boolean;
  /** "native" | "vibrancy" | "none" — what the sidecar can draw. */
  glassSupport: string;
  battery: boolean;
  procStats: boolean;
  respectFocus: boolean;
  focus: { active: boolean; name: string | null; since: string };
  /** The two agent-island:// URLs a Focus automation opens. */
  focusLinks: { on: string; off: string };
  /** False in dev builds and when another app owns the scheme. */
  deepLinksRegistered: boolean;
  openAtLogin: boolean;
  /** macOS 13+ can hold a login item pending the user's approval in System Settings. */
  loginNeedsApproval: boolean;
  version: string;
  /** Newest available version, or null when up to date / not yet checked. */
  update: { version: string } | null;
  /* Intelligence */
  assistant: boolean;
  assistantModel: boolean;
  voice: boolean;
  speakReplies: boolean;
  edgeGlow: boolean;
  greeting: boolean;
  /** "available" | "basic" | "no-helper" — what the assistant can do here. */
  assistantSupport: string;
  /** Why the model can't answer in basic mode (not-enabled, os, off, …). */
  assistantReason: string;
}

export interface PowerPayload {
  percent: number;
  /** "charging" | "discharging" | "charged" | "ac" */
  state: string;
  minutesRemaining: number | null;
  /** "plugged" | "unplugged" on the push that carries the transition, else null. */
  event: string | null;
  /** On battery at or under 20%. */
  low: boolean;
}

export interface FocusPayload {
  active: boolean;
  name: string | null;
  since: string;
  /** Sounds and notification haptics should stay quiet right now. */
  mute: boolean;
}

/** Session key → CPU (% of a core, summed) and memory, or null when the PID is gone. */
export type ProcStatsPayload = Record<string, { cpu: number; rssMb: number; procs: number } | null>;

export interface GreetingPayload {
  title: string;
  line: string;
  /** Written by the on-device model (vs. the built-in fallback). */
  ai: boolean;
}

export type AssistantEventPayload =
  | { id: string; type: "delta"; text: string }
  | { id: string; type: "done" }
  | { id: string; type: "error"; reason: string }
  | { id: string; type: "tool"; name: string; step: string }
  | {
      id: string;
      type: "action";
      action:
        | { kind: "open"; project: string }
        | { kind: "draft"; project: string; message: string }
        | { kind: "timer"; minutes: number; label: string }
        | { kind: "shortcut"; name: string }
        | { kind: "sources"; sources: Array<{ title: string; url: string }> };
    };

export type VoiceEventPayload =
  | { id: string; type: "listening" }
  | { id: string; type: "status"; status: string }
  | { id: string; type: "level"; level: number }
  | { id: string; type: "partial"; text: string }
  | { id: string; type: "final"; text: string }
  | { id: string; type: "error"; reason: string }
  | { id: ""; type: "spoken" };

export interface SessionsPayload {
  sessions: SessionSnapshot[];
  connected: boolean;
}

export interface NotchLayout {
  /** Px between the window's top and the notch's bottom line. */
  inset: number;
  /** Measured hardware notch width; 0 = unknown or no notch. */
  notchWidth: number;
  /** Widest the expanded island may grow on the current display. */
  maxIslandWidth: number;
}

export interface UiPrefs {
  /** "default" | "large" | "larger" — drives --ui-scale. */
  textSize: string;
  /** "hover" | "swipe" — how the collapsed island opens. */
  openWith: string;
  /** "compact" | "detailed" — session bubbles or full rows. */
  sessionView: string;
  assistant?: boolean;
  voice?: boolean;
  speakReplies?: boolean;
  edgeGlow?: boolean;
  greeting?: boolean;
  /** macOS natural scrolling; inverts wheel sign relative to finger motion. */
  naturalScroll: boolean;
  /** "native" | "vibrancy" | "css" — the material the panel should style for. */
  glass: string;
}

export interface WeatherPayload {
  /** One of the ten scenes; see weather-conditions.ts. */
  condition: string;
  temperature: string;
  /** Spoken summary — the animation itself is decorative and aria-hidden. */
  summary: string;
  locationLabel: string;
  locationSource: string;
  /** A cached reading we couldn't refresh. */
  stale: boolean;
}

/** The only surface the renderer can touch — locked down via contextBridge. */
const api = {
  getSessions: (): Promise<SessionsPayload> => ipcRenderer.invoke("agent-island:get-sessions"),

  onSessions: (cb: (payload: SessionsPayload) => void): (() => void) => {
    const listener = (_e: unknown, payload: SessionsPayload) => cb(payload);
    ipcRenderer.on("agent-island:sessions", listener);
    return () => ipcRenderer.removeListener("agent-island:sessions", listener);
  },

  onToggle: (cb: () => void): (() => void) => {
    const listener = () => cb();
    ipcRenderer.on("agent-island:toggle", listener);
    return () => ipcRenderer.removeListener("agent-island:toggle", listener);
  },

  getUsage: (): Promise<AgentUsage[]> => ipcRenderer.invoke("agent-island:get-usage"),

  /**
   * Window geometry: `inset` = px between window top and the notch's bottom
   * line; `notchWidth` = measured hardware notch width (0 = unknown/no notch);
   * `maxIslandWidth` = widest the expanded island may grow on this display.
   */
  getLayout: (): Promise<NotchLayout> => ipcRenderer.invoke("agent-island:get-layout"),

  onLayout: (cb: (layout: NotchLayout) => void): (() => void) => {
    const listener = (_e: unknown, layout: NotchLayout) => cb(layout);
    ipcRenderer.on("agent-island:layout", listener);
    return () => ipcRenderer.removeListener("agent-island:layout", listener);
  },

  /**
   * Report where the island actually is, in window coordinates. The window is
   * far wider than the island, so main needs this to tell whether the pointer
   * has really left the pill.
   */
  reportIslandRect: (
    rect: { x: number; y: number; width: number; height: number },
    panel?: { x: number; y: number; width: number; height: number } | null,
  ): void => ipcRenderer.send("agent-island:island-rect", rect, panel ?? null),

  /**
   * System appearance switches the renderer sees via matchMedia. Main uses
   * them to retire the native glass panel when transparency or contrast
   * settings ask for it.
   */
  reportMediaPrefs: (prefs: { reducedTransparency: boolean; moreContrast: boolean }): void =>
    ipcRenderer.send("agent-island:media-prefs", prefs),

  /** Presentation prefs the overlay needs (text scale). */
  getUiPrefs: (): Promise<UiPrefs> => ipcRenderer.invoke("agent-island:get-ui-prefs"),

  /** Current local weather, or null when it's off or has no reading yet. */
  getWeather: (): Promise<WeatherPayload | null> => ipcRenderer.invoke("agent-island:get-weather"),

  onWeather: (cb: (weather: WeatherPayload | null) => void): (() => void) => {
    const listener = (_e: unknown, weather: WeatherPayload | null) => cb(weather);
    ipcRenderer.on("agent-island:weather", listener);
    return () => ipcRenderer.removeListener("agent-island:weather", listener);
  },

  /** Battery, or null on desktops / when the setting is off. */
  getPower: (): Promise<PowerPayload | null> => ipcRenderer.invoke("agent-island:get-power"),

  onPower: (cb: (power: PowerPayload | null) => void): (() => void) => {
    const listener = (_e: unknown, power: PowerPayload | null) => cb(power);
    ipcRenderer.on("agent-island:power", listener);
    return () => ipcRenderer.removeListener("agent-island:power", listener);
  },

  /** Focus state as reported by the user's Shortcuts automation. */
  getFocus: (): Promise<FocusPayload> => ipcRenderer.invoke("agent-island:get-focus"),

  onFocus: (cb: (focus: FocusPayload) => void): (() => void) => {
    const listener = (_e: unknown, focus: FocusPayload) => cb(focus);
    ipcRenderer.on("agent-island:focus", listener);
    return () => ipcRenderer.removeListener("agent-island:focus", listener);
  },

  /** The footer chip: a Focus whose "off" automation never fired. */
  clearFocus: (): void => ipcRenderer.send("agent-island:clear-focus"),

  /** Per-session resource totals, pushed every 2s while the panel is open. */
  onProcStats: (cb: (stats: ProcStatsPayload) => void): (() => void) => {
    const listener = (_e: unknown, stats: ProcStatsPayload) => cb(stats);
    ipcRenderer.on("agent-island:proc-stats", listener);
    return () => ipcRenderer.removeListener("agent-island:proc-stats", listener);
  },

  onUiPrefs: (cb: (prefs: UiPrefs) => void): (() => void) => {
    const listener = (_e: unknown, prefs: UiPrefs) => cb(prefs);
    ipcRenderer.on("agent-island:ui-prefs", listener);
    return () => ipcRenderer.removeListener("agent-island:ui-prefs", listener);
  },

  /**
   * Request a trackpad haptic. Silently ignored on hardware without a Force
   * Touch trackpad, when the user has haptics off, or when the native helper
   * isn't present — callers never need to check.
   */
  haptic: (pattern: string): void => ipcRenderer.send("agent-island:haptic", pattern),

  /**
   * VoiceOver reach-in: main flips the window focusable and focuses it, then
   * tells us to trap focus. Sent `false` when focus is handed back.
   */
  onA11yFocus: (cb: (focused: boolean) => void): (() => void) => {
    const listener = (_e: unknown, focused: boolean) => cb(focused);
    ipcRenderer.on("agent-island:a11y-focus", listener);
    return () => ipcRenderer.removeListener("agent-island:a11y-focus", listener);
  },

  /** Leave the focus trap (Escape) and give focus back to the previous app. */
  releaseA11yFocus: (): void => ipcRenderer.send("agent-island:a11y-release"),

  /** Fired by main when the cursor leaves the window while it's interactive. */
  onCursorLeft: (cb: () => void): (() => void) => {
    const listener = () => cb();
    ipcRenderer.on("agent-island:cursor-left", listener);
    return () => ipcRenderer.removeListener("agent-island:cursor-left", listener);
  },

  /**
   * Whether the overlay should be animating. Main flips this off when the Mac
   * locks or sleeps (nobody's watching) and on when it wakes — so a long agent
   * run doesn't keep compositing the notch on a screen no one can see.
   */
  onAnimationActive: (cb: (active: boolean) => void): (() => void) => {
    const listener = (_e: unknown, active: boolean) => cb(active);
    ipcRenderer.on("agent-island:animation-active", listener);
    return () => ipcRenderer.removeListener("agent-island:animation-active", listener);
  },

  getSounds: (): Promise<SoundPrefsPayload> => ipcRenderer.invoke("agent-island:get-sounds"),

  onSounds: (cb: (prefs: SoundPrefsPayload) => void): (() => void) => {
    const listener = (_e: unknown, prefs: SoundPrefsPayload) => cb(prefs);
    ipcRenderer.on("agent-island:sounds", listener);
    return () => ipcRenderer.removeListener("agent-island:sounds", listener);
  },

  onUsage: (cb: (usage: AgentUsage[]) => void): (() => void) => {
    const listener = (_e: unknown, usage: AgentUsage[]) => cb(usage);
    ipcRenderer.on("agent-island:usage", listener);
    return () => ipcRenderer.removeListener("agent-island:usage", listener);
  },

  /** Flip window click-through: true = capture mouse, false = pass through.
   *  `reason` is a comma list of what holds the island open, for the log. */
  setInteractive: (interactive: boolean, reason = ""): void =>
    ipcRenderer.send("agent-island:set-interactive", interactive, reason),

  /** Bring the session's terminal to the front. */
  jump: (session: SessionSnapshot): void => ipcRenderer.send("agent-island:jump", session),

  /** Answer a pending question: one 0-based option index per sub-question. */
  /** The chosen option indices per question (several for a multi-select). */
  answer: (session: SessionSnapshot, selections: number[][]): void =>
    ipcRenderer.send("agent-island:answer", { session, selections }),

  /** Type a free-form prompt into the session's terminal and submit it. */
  sendPrompt: (session: SessionSnapshot, text: string): void =>
    ipcRenderer.send("agent-island:send-prompt", { session, text }),

  /**
   * Toggle keyboard focus for the prompt input. The overlay is non-focusable by
   * default (so it never steals focus from the terminal); flip it on only while
   * the user is typing a prompt, then off again.
   */
  setPromptComposing: (active: boolean): void =>
    ipcRenderer.send("agent-island:prompt-composing", active),

  /** Result of the last send-prompt: "sent" | "no-accessibility" | "empty". */
  onPromptStatus: (cb: (status: string) => void): (() => void) => {
    const listener = (_e: unknown, status: string) => cb(status);
    ipcRenderer.on("agent-island:prompt-status", listener);
    return () => ipcRenderer.removeListener("agent-island:prompt-status", listener);
  },

  /* ---- Apple Intelligence (on-device, via the native sidecar) ---- */

  /** "available", or why not: "not-enabled", "device-not-eligible", "os", … */
  getAssistant: (): Promise<string> => ipcRenderer.invoke("agent-island:get-assistant"),

  onAssistantSupport: (cb: (support: string) => void): (() => void) => {
    const listener = (_e: unknown, support: string) => cb(support);
    ipcRenderer.on("agent-island:assistant-support", listener);
    return () => ipcRenderer.removeListener("agent-island:assistant-support", listener);
  },

  /** Ask a question; `context` is a plain-text snapshot of the sessions. */
  askAssistant: (id: string, prompt: string, context: string): void =>
    ipcRenderer.send("agent-island:assistant-ask", { id, prompt, context }),

  /** The launch hello, once per launch; null when off or already said. */
  getGreeting: (): Promise<GreetingPayload | null> => ipcRenderer.invoke("agent-island:get-greeting"),

  /** A welcome-back hello after time away from the Mac. */
  onGreeting: (cb: (g: GreetingPayload) => void): (() => void) => {
    const listener = (_e: unknown, g: GreetingPayload) => cb(g);
    ipcRenderer.on("agent-island:greeting", listener);
    return () => ipcRenderer.removeListener("agent-island:greeting", listener);
  },

  /** Open a web result the assistant cited (http/https only; main checks). */
  openSource: (url: string): void => ipcRenderer.send("agent-island:open-source", url),

  cancelAssistant: (id: string): void => ipcRenderer.send("agent-island:assistant-cancel", id),

  /** Run a Shortcut the model proposed — only after the user clicked Run. */
  runShortcut: (name: string): Promise<boolean> =>
    ipcRenderer.invoke("agent-island:assistant-run-shortcut", name),

  /** A timer the assistant started has ended (its label, possibly empty). */
  onAssistantTimer: (cb: (label: string) => void): (() => void) => {
    const listener = (_e: unknown, label: string) => cb(label);
    ipcRenderer.on("agent-island:assistant-timer", listener);
    return () => ipcRenderer.removeListener("agent-island:assistant-timer", listener);
  },

  /* ---- Voice mode (Swift sidecar: on-device listening and speech) ---- */

  startVoice: (id: string): void => ipcRenderer.send("agent-island:voice-start", id),
  stopVoice: (id: string): void => ipcRenderer.send("agent-island:voice-stop", id),
  speak: (text: string): void => ipcRenderer.send("agent-island:speak", text),
  stopSpeaking: (): void => ipcRenderer.send("agent-island:speak-stop"),
  onVoiceEvent: (cb: (event: VoiceEventPayload) => void): (() => void) => {
    const listener = (_e: unknown, event: VoiceEventPayload) => cb(event);
    ipcRenderer.on("agent-island:voice-event", listener);
    return () => ipcRenderer.removeListener("agent-island:voice-event", listener);
  },

  /** Start a fresh conversation. */
  resetAssistant: (): void => ipcRenderer.send("agent-island:assistant-reset"),

  /** Streamed reply text (cumulative), done, error, or a tool action. */
  onAssistantEvent: (cb: (event: AssistantEventPayload) => void): (() => void) => {
    const listener = (_e: unknown, event: AssistantEventPayload) => cb(event);
    ipcRenderer.on("agent-island:assistant-event", listener);
    return () => ipcRenderer.removeListener("agent-island:assistant-event", listener);
  },

  /** Prompt macOS for Accessibility and open the pane (shared with onboarding). */
  openAccessibility: (): void => ipcRenderer.send("agent-island:enable-accessibility"),

  /** One-shot chime pushed by main (e.g. "approve" after allowing something). */
  onChime: (cb: (event: string) => void): (() => void) => {
    const listener = (_e: unknown, event: string) => cb(event);
    ipcRenderer.on("agent-island:chime", listener);
    return () => ipcRenderer.removeListener("agent-island:chime", listener);
  },

  /** Resolve a pending approval from the notch. */
  approve: (id: string, decision: ApprovalDecision): void =>
    ipcRenderer.send("agent-island:approve", { id, decision }),

  /** Toggle sound effects (persisted in main for this run). */
  setSounds: (on: boolean): void => ipcRenderer.send("agent-island:set-sounds", on),

  /** A newer release exists on GitHub (update notifier, not auto-update). */
  onUpdate: (cb: (info: { version: string }) => void): (() => void) => {
    const listener = (_e: unknown, info: { version: string }) => cb(info);
    ipcRenderer.on("agent-island:update", listener);
    return () => ipcRenderer.removeListener("agent-island:update", listener);
  },

  /** Open the latest release's download page in the browser. */
  openUpdate: (): void => ipcRenderer.send("agent-island:open-update"),

  quit: (): void => ipcRenderer.send("agent-island:quit"),

  /** Open the Settings window. */
  openSettings: (): void => ipcRenderer.send("agent-island:open-settings"),

  /** Window chrome for frameless windows (settings/onboarding). */
  winClose: (): void => ipcRenderer.send("agent-island:win-close"),
  winMinimize: (): void => ipcRenderer.send("agent-island:win-minimize"),

  /* ---- Settings window ---- */

  settings: {
    get: (): Promise<SettingsState> => ipcRenderer.invoke("agent-island:get-settings"),
    onState: (cb: (state: SettingsState) => void): (() => void) => {
      const listener = (_e: unknown, state: SettingsState) => cb(state);
      ipcRenderer.on("agent-island:settings-state", listener);
      return () => ipcRenderer.removeListener("agent-island:settings-state", listener);
    },
    set: (key: string, value: boolean | string): void =>
      ipcRenderer.send("agent-island:set-setting", { key, value }),
    /** Open a file picker to import a custom sound for `event`. Resolves true if set. */
    importSound: (event: string): Promise<boolean> =>
      ipcRenderer.invoke("agent-island:import-sound", event),
    /** Remove the imported custom sound for `event` (revert to theme). */
    clearSound: (event: string): void => ipcRenderer.send("agent-island:clear-sound", event),
    /** Check for a newer release right now; resolves the newest version (or null). */
    checkUpdates: (): Promise<{ version: string } | null> =>
      ipcRenderer.invoke("agent-island:check-updates"),
    /** Download the newest DMG and self-replace + relaunch. Resolves false if it can't. */
    installUpdate: (): Promise<boolean> => ipcRenderer.invoke("agent-island:install-update"),
    /** Open the Shortcuts app so the user can add the Focus automations. */
    openShortcuts: (): void => ipcRenderer.send("agent-island:open-shortcuts"),
  },

  /* ---- Onboarding (first-run window only) ---- */

  onboarding: {
    getState: (): Promise<{ accessibilityTrusted: boolean; openAtLogin: boolean }> =>
      ipcRenderer.invoke("agent-island:onboarding-state"),
    onState: (
      cb: (state: { accessibilityTrusted: boolean; openAtLogin: boolean }) => void,
    ): (() => void) => {
      const listener = (
        _e: unknown,
        state: { accessibilityTrusted: boolean; openAtLogin: boolean },
      ) => cb(state);
      ipcRenderer.on("agent-island:onboarding-state", listener);
      return () => ipcRenderer.removeListener("agent-island:onboarding-state", listener);
    },
    enableAccessibility: (): void => ipcRenderer.send("agent-island:enable-accessibility"),
    setLogin: (on: boolean): void => ipcRenderer.send("agent-island:set-login", on),
    finish: (): void => ipcRenderer.send("agent-island:finish-onboarding"),
  },
};

contextBridge.exposeInMainWorld("agentIsland", api);

export type AgentIslandApi = typeof api;
