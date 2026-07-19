import { contextBridge, ipcRenderer } from "electron";
import type { AgentUsage, ApprovalDecision, SessionSnapshot } from "@agent-island/shared";

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

  getSounds: (): Promise<boolean> => ipcRenderer.invoke("agent-island:get-sounds"),

  onSounds: (cb: (on: boolean) => void): (() => void) => {
    const listener = (_e: unknown, on: boolean) => cb(on);
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

  /** Answer a pending question by typing its option number into the terminal. */
  answer: (session: SessionSnapshot, digit: number): void =>
    ipcRenderer.send("agent-island:answer", { session, digit }),

  /** Resolve a pending approval from the notch. */
  approve: (id: string, decision: ApprovalDecision): void =>
    ipcRenderer.send("agent-island:approve", { id, decision }),

  /** Toggle sound effects (persisted in main for this run). */
  setSounds: (on: boolean): void => ipcRenderer.send("agent-island:set-sounds", on),

  quit: (): void => ipcRenderer.send("agent-island:quit"),

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
