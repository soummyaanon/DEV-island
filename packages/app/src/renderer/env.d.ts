/// <reference types="vite/client" />
import type { AgentIslandApi } from "../preload";

declare global {
  interface Window {
    agentIsland: AgentIslandApi;
  }
}

export {};
