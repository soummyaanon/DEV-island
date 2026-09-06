import { StrictMode, useEffect, useState } from "react";
import { createRoot } from "react-dom/client";
import { PixelSprite } from "./PixelSprite";
import { OpenAiSprite } from "./OpenAiSprite";
import { CursorSprite } from "./CursorSprite";
import { TrafficLights } from "./TrafficLights";
import { previewSound, previewCustom } from "./sounds";
import {
  EVENT_LABELS,
  SOUND_EVENTS,
  SOUND_THEMES,
  THEME_LABELS,
  resolveTheme,
  type SoundEvent,
  type SoundPrefs,
  type SoundTheme,
} from "./sound-prefs";
import "./styles/window-chrome.css";
import "./styles/settings.css";

interface SettingsState {
  agents: Record<string, boolean>;
  sounds: boolean;
  soundTheme: string;
  soundOverrides: Record<string, string>;
  customSounds: Record<string, string>;
  customSoundNames: Record<string, string>;
  tray: boolean;
  updateCheck: boolean;
  haptics: boolean;
  textSize: string;
  hapticsSupported: boolean;
  a11yShortcut: string | null;
  weather: boolean;
  weatherLocation: string;
  weatherUnits: string;
  openWith: string;
  openAtLogin: boolean;
  version: string;
  update: { version: string } | null;
}

const DEFAULTS: SettingsState = {
  agents: { "claude-code": true, codex: true, cursor: true },
  sounds: true,
  soundTheme: "8bit",
  soundOverrides: {},
  customSounds: {},
  customSoundNames: {},
  tray: false,
  updateCheck: true,
  haptics: true,
  textSize: "default",
  hapticsSupported: false,
  a11yShortcut: null,
  weather: false,
  weatherLocation: "",
  weatherUnits: "auto",
  openWith: "hover",
  openAtLogin: false,
  version: "",
  update: null,
};

const NAV = [
  { id: "integrations", label: "Integrations", icon: "❖" },
  { id: "appearance", label: "Appearance", icon: "◐" },
  { id: "sounds", label: "Sounds", icon: "♪" },
  { id: "weather", label: "Weather", icon: "☂" },
  { id: "accessibility", label: "Accessibility", icon: "◍" },
  { id: "general", label: "General", icon: "⚙" },
  { id: "updates", label: "Updates", icon: "↑" },
] as const;
type SectionId = (typeof NAV)[number]["id"];

const TEMPERATURE_UNITS = [
  { value: "auto", label: "Automatic" },
  { value: "c", label: "Celsius" },
  { value: "f", label: "Fahrenheit" },
] as const;

/** How the coordinates were obtained, said plainly — a guess shouldn't look like a fix. */
const LOCATION_SOURCE_LABEL: Record<string, string> = {
  manual: "the location you entered",
  device: "your device location",
  timezone: "your time zone (approximate)",
};

const TEXT_SIZES = [
  { value: "default", label: "Default" },
  { value: "large", label: "Large" },
  { value: "larger", label: "Larger" },
] as const;

/** "Control+Alt+Command+I" -> "⌃⌥⌘I", the way macOS writes it. */
function prettyShortcut(accelerator: string): string {
  const glyphs: Record<string, string> = {
    Control: "⌃",
    Alt: "⌥",
    Option: "⌥",
    Shift: "⇧",
    Command: "⌘",
    CommandOrControl: "⌘",
  };
  return accelerator
    .split("+")
    .map((part) => glyphs[part] ?? part)
    .join("");
}

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

const OPEN_WITH: { value: string; label: string }[] = [
  { value: "hover", label: "Hover" },
  { value: "swipe", label: "Swipe" },
];

/** A small segmented control — one choice among a few, all visible at once. */
function Segmented({
  value,
  options,
  onChange,
  label,
}: {
  value: string;
  options: { value: string; label: string }[];
  onChange: (next: string) => void;
  label: string;
}) {
  return (
    <div className="s-seg" role="radiogroup" aria-label={label}>
      {options.map((o) => (
        <button
          key={o.value}
          type="button"
          role="radio"
          aria-checked={value === o.value}
          className={`s-seg-item${value === o.value ? " on" : ""}`}
          onClick={() => onChange(o.value)}
        >
          {o.label}
        </button>
      ))}
    </div>
  );
}

function Settings() {
  const [state, setState] = useState<SettingsState>(DEFAULTS);
  const [checking, setChecking] = useState(false);
  const [installing, setInstalling] = useState(false);
  const [section, setSection] = useState<SectionId>("integrations");
  // Which location layer actually answered, so the panel can say so rather than
  // implying a precision it doesn't have.
  const [locationSource, setLocationSource] = useState<string | null>(null);
  const weatherSource = locationSource ? LOCATION_SOURCE_LABEL[locationSource] : null;

  useEffect(() => {
    void window.agentIsland.getWeather?.().then((w) => setLocationSource(w?.locationSource ?? null));
    return window.agentIsland.onWeather?.((w) => setLocationSource(w?.locationSource ?? null));
  }, []);

  useEffect(() => {
    if (!window.agentIsland?.settings) return; // plain-browser preview
    void window.agentIsland.settings.get().then(setState);
    return window.agentIsland.settings.onState(setState);
  }, []);

  // Check the moment Settings opens, so the status is fresh without waiting for
  // the hourly background check.
  useEffect(() => {
    if (!window.agentIsland?.settings?.checkUpdates) return;
    setChecking(true);
    void window.agentIsland.settings.checkUpdates().finally(() => setChecking(false));
  }, []);

  const set = (key: string, value: boolean | string) => {
    window.agentIsland?.settings?.set(key, value);
    // optimistic; main pushes the authoritative state right back
    setState((s) => {
      if (key.startsWith("agent:"))
        return { ...s, agents: { ...s.agents, [key.slice(6)]: value === true } };
      if (key.startsWith("soundOverride:")) {
        const overrides = { ...s.soundOverrides };
        if (typeof value === "string" && value) overrides[key.slice(14)] = value;
        else delete overrides[key.slice(14)];
        return { ...s, soundOverrides: overrides };
      }
      return { ...s, [key]: value };
    });
  };

  const soundPrefs: SoundPrefs = {
    on: state.sounds,
    theme: state.soundTheme as SoundTheme,
    overrides: state.soundOverrides as SoundPrefs["overrides"],
    custom: state.customSounds as SoundPrefs["custom"],
  };

  const activeLabel = NAV.find((n) => n.id === section)?.label ?? "";

  return (
    <div className="settings">
      <aside className="s-sidebar">
        <div className="drag-strip" />
        <TrafficLights
          onClose={() => window.agentIsland?.winClose()}
          onMinimize={() => window.agentIsland?.winMinimize()}
        />
        <div className="s-brand">Agent Island</div>
        <nav className="s-nav">
          {NAV.map((n) => (
            <button
              key={n.id}
              type="button"
              className={`s-nav-item${section === n.id ? " active" : ""}`}
              onClick={() => setSection(n.id)}
            >
              <span className="s-nav-ic" aria-hidden>
                {n.icon}
              </span>
              {n.label}
              {n.id === "updates" && state.update && <span className="s-nav-dot" aria-hidden />}
            </button>
          ))}
        </nav>
        <div className="s-side-foot">
          {state.version && `v${state.version}`}
          <span>everything stays on this Mac</span>
        </div>
      </aside>

      <main className="s-detail">
        <h1>{activeLabel}</h1>

        {section === "integrations" && (
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
        )}

        {section === "appearance" && (
          <div className="s-group">
            <div className="s-row">
              <div className="s-text">
                <b>Open with</b>
                <span>
                  {state.openWith === "swipe"
                    ? "Two-finger swipe down (or a click) opens the island; grazing the top of the screen doesn't. Swipe up closes it."
                    : "Hovering the notch opens the island. Swipe up closes it either way."}
                </span>
              </div>
              <Segmented
                label="Open the island with"
                value={state.openWith}
                options={OPEN_WITH}
                onChange={(v) => set("openWith", v)}
              />
            </div>
          </div>
        )}

        {section === "sounds" && (
          <div className="s-group">
            <Row
              title="Sound effects"
              detail="Chimes when agents finish, ask, need you — and when you allow."
              on={state.sounds}
              onChange={(v) => set("sounds", v)}
            />
            <div className="s-row">
              <div className="s-text">
                <b>Theme</b>
                <span>The sound set for all events.</span>
              </div>
              <select
                className="s-select"
                value={state.soundTheme}
                onChange={(e) => set("soundTheme", e.target.value)}
              >
                {SOUND_THEMES.map((t) => (
                  <option key={t} value={t}>
                    {THEME_LABELS[t]}
                  </option>
                ))}
              </select>
            </div>
            {SOUND_EVENTS.map((event: SoundEvent) => {
              const custom = state.customSounds[event];
              const customName = state.customSoundNames[event] || "Custom";
              return (
                <div className="s-row s-sub" key={event}>
                  <div className="s-text">
                    <b>{EVENT_LABELS[event]}</b>
                  </div>
                  <button
                    type="button"
                    className="s-play"
                    title="Preview"
                    onClick={() =>
                      custom
                        ? previewCustom(custom)
                        : previewSound(event, resolveTheme(event, soundPrefs))
                    }
                  >
                    ▶
                  </button>
                  {custom ? (
                    <span className="s-custom" title={`Playing your imported sound: ${customName}`}>
                      <span className="s-custom-tag">{customName}</span>
                      <button
                        type="button"
                        className="s-play s-clear"
                        title="Remove custom sound"
                        onClick={() => window.agentIsland?.settings?.clearSound(event)}
                      >
                        ✕
                      </button>
                    </span>
                  ) : (
                    <select
                      className="s-select"
                      value={state.soundOverrides[event] ?? ""}
                      onChange={(e) => set(`soundOverride:${event}`, e.target.value)}
                    >
                      <option value="">Theme default</option>
                      {SOUND_THEMES.map((t) => (
                        <option key={t} value={t}>
                          {THEME_LABELS[t]}
                        </option>
                      ))}
                    </select>
                  )}
                  <button
                    type="button"
                    className="s-import"
                    title="Import your own audio file (mp3, wav, m4a…)"
                    onClick={() => void window.agentIsland?.settings?.importSound(event)}
                  >
                    {custom ? "Replace" : "Import"}
                  </button>
                </div>
              );
            })}
          </div>
        )}

        {section === "weather" && (
          <div className="s-group">
            <Row
              title="Local weather"
              detail="Animates in the island whenever no agent is working. Off by default."
              on={state.weather}
              onChange={(v) => set("weather", v)}
            />
            <div className="s-row s-sub">
              <div className="s-text">
                <b>Location</b>
                <span>
                  Blank uses your time zone — no permission needed, accurate to the nearest big
                  city. Enter “latitude, longitude” to be exact.
                </span>
              </div>
              <input
                className="s-input"
                type="text"
                placeholder="22.57, 88.36"
                aria-label="Weather location as latitude, longitude"
                defaultValue={state.weatherLocation}
                spellCheck={false}
                // On blur, not per keystroke: every change is a network request.
                onBlur={(e) => set("weatherLocation", e.target.value)}
                onKeyDown={(e) => {
                  if (e.key === "Enter") e.currentTarget.blur();
                }}
              />
            </div>
            <div className="s-row s-sub">
              <div className="s-text">
                <b>Units</b>
                <span>Automatic follows your Mac’s region.</span>
              </div>
              <select
                className="s-select"
                value={state.weatherUnits}
                onChange={(e) => set("weatherUnits", e.target.value)}
              >
                {TEMPERATURE_UNITS.map((u) => (
                  <option key={u.value} value={u.value}>
                    {u.label}
                  </option>
                ))}
              </select>
            </div>
            <div className="s-row s-sub">
              <div className="s-text">
                <span>
                  {state.weather ? (
                    <>
                      Weather comes from open-meteo.com — no account, no API key. Your coordinates
                      are rounded to about a kilometre before the request, and nothing else about
                      you or your sessions is sent.
                      {weatherSource ? ` Currently using ${weatherSource}.` : ""}
                    </>
                  ) : (
                    <>
                      While this is off, Agent Island makes no weather requests at all. Turning it
                      on adds one request to open-meteo.com every 15 minutes.
                    </>
                  )}
                </span>
              </div>
            </div>
          </div>
        )}

        {section === "accessibility" && (
          <div className="s-group">
            <Row
              title="Haptic feedback"
              detail={
                state.hapticsSupported
                  ? "A distinct tap for finishing, failing, asking, and deciding. Force Touch trackpads only."
                  : "Unavailable on this install — the native helper wasn't built, so there's nothing to tap."
              }
              on={state.haptics && state.hapticsSupported}
              onChange={(v) => set("haptics", v)}
            />
            <div className="s-row">
              <div className="s-text">
                <b>Text size</b>
                <span>Scales everything in the island. macOS has no system setting we can read.</span>
              </div>
              <select
                className="s-select"
                value={state.textSize}
                onChange={(e) => set("textSize", e.target.value)}
              >
                {TEXT_SIZES.map((t) => (
                  <option key={t.value} value={t.value}>
                    {t.label}
                  </option>
                ))}
              </select>
            </div>
            <div className="s-row">
              <div className="s-text">
                <b>Focus the island</b>
                <span>
                  {state.a11yShortcut
                    ? "The island never takes focus on its own, so VoiceOver can't reach it. This hands it focus; Escape gives it back."
                    : "Unavailable — another app already holds this shortcut."}
                </span>
              </div>
              {state.a11yShortcut ? (
                <kbd className="s-kbd">{prettyShortcut(state.a11yShortcut)}</kbd>
              ) : null}
            </div>
            <div className="s-row s-sub">
              <div className="s-text">
                <span>
                  Reduce motion, Increase contrast, and Reduce transparency are followed
                  automatically from System Settings → Accessibility → Display.
                </span>
              </div>
            </div>
          </div>
        )}

        {section === "general" && (
          <div className="s-group">
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
              detail="One anonymous version check against GitHub Releases, hourly."
              on={state.updateCheck}
              onChange={(v) => set("updateCheck", v)}
            />
          </div>
        )}

        {section === "updates" && (
          <div className="s-group">
            <div className="s-row">
              <div className="s-text">
                <b>
                  {state.update ? `Update available — v${state.update.version}` : "Agent Island"}
                </b>
                <span>
                  {state.update
                    ? `You're on v${state.version}. Installing replaces the app and relaunches.`
                    : checking
                      ? "Checking for updates…"
                      : `You're on v${state.version} — up to date.`}
                </span>
              </div>
              {state.update ? (
                <button
                  type="button"
                  className="s-import s-install"
                  disabled={installing}
                  onClick={() => {
                    setInstalling(true);
                    // On success the app quits and relaunches, so we only re-enable on failure.
                    void window.agentIsland?.settings?.installUpdate().then((ok) => {
                      if (!ok) setInstalling(false);
                    });
                  }}
                >
                  {installing ? "Installing…" : "Install & Restart"}
                </button>
              ) : (
                <button
                  type="button"
                  className="s-import"
                  disabled={checking}
                  onClick={() => {
                    setChecking(true);
                    void window.agentIsland?.settings
                      ?.checkUpdates()
                      .finally(() => setChecking(false));
                  }}
                >
                  {checking ? "Checking…" : "Check now"}
                </button>
              )}
            </div>
            {state.update && (
              <div className="s-note">
                After updating, re-enable Agent Island in System Settings → Privacy &amp; Security →
                Accessibility (ad-hoc builds lose the grant on replace).
              </div>
            )}
          </div>
        )}
      </main>
    </div>
  );
}

createRoot(document.getElementById("root")!).render(
  <StrictMode>
    <Settings />
  </StrictMode>,
);
