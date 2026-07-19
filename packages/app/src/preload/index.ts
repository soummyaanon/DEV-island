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
  tray: boolean;
  updateCheck: boolean;
  openAtLogin: boolean;
  version: string;
  /** Newest available version, or null when up to date / not yet checked. */
  update: { version: string } | null;
}

export interface SessionsPayload {
  sessions: SessionSnapshot[];
  connected: boolean;
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
   * line; `notchWidth` = measured hardware notch width (0 = unknown/no notch).
   */
  getLayout: (): Promise<{ inset: number; notchWidth: number }> =>
    ipcRenderer.invoke("agent-island:get-layout"),

  onLayout: (cb: (layout: { inset: number; notchWidth: number }) => void): (() => void) => {
    const listener = (_e: unknown, layout: { inset: number; notchWidth: number }) => cb(layout);
    ipcRenderer.on("agent-island:layout", listener);
    return () => ipcRenderer.removeListener("agent-island:layout", listener);
  },

  /** Fired by main when the cursor leaves the window while it's interactive. */
  onCursorLeft: (cb: () => void): (() => void) => {
    const listener = () => cb();
    ipcRenderer.on("agent-island:cursor-left", listener);
    return () => ipcRenderer.removeListener("agent-island:cursor-left", listener);
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

  /** Flip window click-through: true = capture mouse, false = pass through. */
  setInteractive: (interactive: boolean): void =>
    ipcRenderer.send("agent-island:set-interactive", interactive),

  /** Bring the session's terminal to the front. */
  jump: (session: SessionSnapshot): void => ipcRenderer.send("agent-island:jump", session),

  /** Answer a pending question: one 0-based option index per sub-question. */
  answer: (session: SessionSnapshot, options: number[]): void =>
    ipcRenderer.send("agent-island:answer", { session, options }),

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
