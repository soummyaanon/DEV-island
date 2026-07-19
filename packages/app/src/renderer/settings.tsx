import { StrictMode, useEffect, useState } from "react";
import { createRoot } from "react-dom/client";
import { PixelSprite } from "./PixelSprite";
import { OpenAiSprite } from "./OpenAiSprite";
import { CursorSprite } from "./CursorSprite";
import { TrafficLights } from "./TrafficLights";
import "./styles/window-chrome.css";
import "./styles/settings.css";

interface SettingsState {
  agents: Record<string, boolean>;
  sounds: boolean;
  tray: boolean;
  updateCheck: boolean;
  openAtLogin: boolean;
  version: string;
}

const DEFAULTS: SettingsState = {
  agents: { "claude-code": true, codex: true, cursor: true },
  sounds: true,
  tray: false,
  updateCheck: true,
  openAtLogin: false,
  version: "",
};

function Toggle({ on, onChange }: { on: boolean; onChange: (next: boolean) => void }) {
  return (
    <button
      className={`switch${on ? " on" : ""}`}
      role="switch"
      aria-checked={on}
      onClick={() => onChange(!on)}
    >
      <i />
    </button>
  );
}

function Row({
  icon,
  title,
  detail,
  on,
  onChange,
}: {
  icon?: React.ReactNode;
  title: string;
  detail: string;
  on: boolean;
  onChange: (next: boolean) => void;
}) {
  return (
    <div className="s-row">
      {icon && <span className="s-icon">{icon}</span>}
      <div className="s-text">
        <b>{title}</b>
        <span>{detail}</span>
      </div>
      <Toggle on={on} onChange={onChange} />
    </div>
  );
}

function Settings() {
  const [state, setState] = useState<SettingsState>(DEFAULTS);

  useEffect(() => {
    if (!window.agentIsland?.settings) return; // plain-browser preview
    void window.agentIsland.settings.get().then(setState);
    return window.agentIsland.settings.onState(setState);
  }, []);

  const set = (key: string, value: boolean) => {
    window.agentIsland?.settings?.set(key, value);
    // optimistic; main pushes the authoritative state right back
    setState((s) =>
      key.startsWith("agent:")
        ? { ...s, agents: { ...s.agents, [key.slice(6)]: value } }
        : { ...s, [key]: value },
    );
  };

  return (
    <div className="settings">
      <div className="drag-strip" />
      <TrafficLights
        onClose={() => window.agentIsland?.winClose()}
        onMinimize={() => window.agentIsland?.winMinimize()}
      />
      <h1>Settings</h1>

      <h2>Integrations</h2>
      <div className="s-group">
        <Row
          icon={<PixelSprite live />}
          title="Claude Code"
          detail="Lifecycle hooks in ~/.claude/settings.json — removed cleanly when off."
          on={state.agents["claude-code"] !== false}
          onChange={(v) => set("agent:claude-code", v)}
        />
        <Row
          icon={<OpenAiSprite live />}
          title="Codex"
          detail="Read-only tail of local session logs. Nothing to install."
          on={state.agents.codex !== false}
          onChange={(v) => set("agent:codex", v)}
        />
        <Row
          icon={<CursorSprite live />}
          title="Cursor"
          detail="Bridge in ~/.cursor/hooks.json — removed cleanly when off."
          on={state.agents.cursor !== false}
          onChange={(v) => set("agent:cursor", v)}
        />
      </div>

      <h2>General</h2>
      <div className="s-group">
        <Row
          title="Sound effects"
          detail="8-bit chimes when agents finish, fail, or need you."
          on={state.sounds}
          onChange={(v) => set("sounds", v)}
        />
        <Row
          title="Open at login"
          detail="Start silently with your Mac — no Dock, no windows."
          on={state.openAtLogin}
          onChange={(v) => set("openAtLogin", v)}
        />
        <Row
          title="Menu-bar icon"
          detail="Optional 🏝 in the menu bar with a status count."
          on={state.tray}
          onChange={(v) => set("tray", v)}
        />
        <Row
          title="Check for updates"
          detail="One anonymous version check against GitHub Releases."
          on={state.updateCheck}
          onChange={(v) => set("updateCheck", v)}
        />
      </div>

      <div className="s-footer">Agent Island {state.version && `v${state.version}`} · everything stays on this Mac</div>
    </div>
  );
}

createRoot(document.getElementById("root")!).render(
  <StrictMode>
    <Settings />
  </StrictMode>,
);
