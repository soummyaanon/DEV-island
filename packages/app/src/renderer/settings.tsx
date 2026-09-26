import { StrictMode, useEffect, useState, type CSSProperties } from "react";
import { createRoot } from "react-dom/client";
import { BotAvatar } from "bot-avatars";
import { ClaudeSprite } from "./ClaudeSprite";
import { OpenAiSprite } from "./OpenAiSprite";
import { CursorSprite } from "./CursorSprite";
import { Icon } from "./Icons";
import { previewSound, previewCustom } from "./sounds";
import {
  EVENT_LABELS,
  SOUND_EVENTS,
  SOUND_THEMES,
  THEME_BLURBS,
  THEME_LABELS,
  resolveTheme,
  type SoundEvent,
  type SoundPrefs,
  type SoundTheme,
} from "./sound-prefs";
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
  sessionView: string;
  glass: boolean;
  glassSupport: string;
  battery: boolean;
  procStats: boolean;
  respectFocus: boolean;
  focus: { active: boolean; name: string | null; since: string };
  focusLinks: { on: string; off: string };
  deepLinksRegistered: boolean;
  openAtLogin: boolean;
  /** macOS 13+ can hold a login item pending the user's approval in System Settings. */
  loginNeedsApproval?: boolean;
  version: string;
  update: { version: string } | null;
  assistant: boolean;
  assistantModel: boolean;
  voice: boolean;
  speakReplies: boolean;
  edgeGlow: boolean;
  greeting: boolean;
  /** "available" | "basic" | "no-helper" */
  assistantSupport: string;
  /** Why the model can't answer in basic mode. */
  assistantReason: string;
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
  openWith: "swipe",
  sessionView: "compact",
  glass: false,
  glassSupport: "none",
  battery: true,
  procStats: true,
  respectFocus: true,
  focus: { active: false, name: null, since: "" },
  focusLinks: { on: "agent-island://focus/on?name=Work", off: "agent-island://focus/off" },
  deepLinksRegistered: false,
  openAtLogin: false,
  version: "",
  update: null,
  assistant: true,
  assistantModel: true,
  voice: true,
  speakReplies: true,
  edgeGlow: true,
  greeting: true,
  assistantSupport: "no-helper",
  assistantReason: "",
};

const NAV = [
  { id: "integrations", label: "Integrations", icon: "integrations", tile: "#ff8c42" },
  { id: "intelligence", label: "Intelligence", icon: "sparkles", tile: "#a77bff" },
  { id: "appearance", label: "Appearance", icon: "appearance", tile: "#3d8bff" },
  { id: "sounds", label: "Sounds", icon: "sounds", tile: "#ff5a7a" },
  { id: "weather", label: "Weather", icon: "weather", tile: "#35b8ff" },
  { id: "live", label: "Live activities", icon: "live", tile: "#2fcb7a" },
  { id: "accessibility", label: "Accessibility", icon: "accessibility", tile: "#3d6bff" },
  { id: "general", label: "General", icon: "general", tile: "#8e8e93" },
  { id: "updates", label: "Updates", icon: "updates", tile: "#ffb020" },
] as const;
type SectionId = (typeof NAV)[number]["id"];

/** One line under each section title: what lives here, in plain words. */
const SECTION_BLURB: Record<SectionId, string> = {
  integrations: "Which agents the island watches.",
  intelligence: "The on-device assistant, its voice, and its glow.",
  appearance: "How the island looks and opens.",
  sounds: "What you hear when agents finish, ask, or need you.",
  weather: "A small live scene when nothing is running.",
  live: "Battery, Focus and resource moments in the wings.",
  accessibility: "Text size, keyboard focus and VoiceOver.",
  general: "Login, menu bar and the app itself.",
  updates: "Stay on the latest release.",
};

/** Where the assistant stands on this Mac, said plainly. */
function assistantStatus(support: string, reason: string, modelOn: boolean): { tone: "ok" | "warn" | "off"; text: string } {
  if (support === "no-helper") return { tone: "off", text: "Unavailable: the native helper isn't installed." };
  if (support === "available")
    return { tone: "ok", text: "Apple Intelligence is ready. Answers and actions run on this Mac." };
  const why: Record<string, string> = {
    off: modelOn ? "Starting Apple Intelligence…" : "Answers are off. Commands still work.",
    "not-enabled": "Turn on Apple Intelligence in System Settings for answers. Commands work now.",
    "model-not-ready": "Apple Intelligence is still downloading its model. Commands work now.",
    "device-not-eligible": "This Mac can't run Apple Intelligence. Commands (open, search, timers, volume, Shortcuts) work.",
    os: "Answers need macOS 26. Commands (open, search, timers, volume, Shortcuts) work now.",
    sdk: "This build has no Apple Intelligence. Commands work.",
  };
  return { tone: "warn", text: why[reason] ?? "Commands work; answers need Apple Intelligence." };
}

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

const SESSION_VIEWS: { value: string; label: string }[] = [
  { value: "compact", label: "Compact" },
  { value: "detailed", label: "Detailed" },
];

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

/** One agent-island:// URL with a copy button, for the Focus automation. */
function LinkRow({ label, url }: { label: string; url: string }) {
  const [copied, setCopied] = useState(false);
  return (
    <div className="s-row s-sub">
      <div className="s-text">
        <b>{label}</b>
        <span>
          <code className="s-code">{url}</code>
        </span>
      </div>
      <button
        type="button"
        className="s-import"
        onClick={() => {
          void navigator.clipboard.writeText(url).then(() => {
            setCopied(true);
            window.setTimeout(() => setCopied(false), 1200);
          });
        }}
      >
        {copied ? "Copied" : "Copy"}
      </button>
    </div>
  );
}

function Settings() {
  const [state, setState] = useState<SettingsState>(DEFAULTS);
  const [checking, setChecking] = useState(false);
  const [installing, setInstalling] = useState(false);
  // `settings.html#sounds` opens straight on a section.
  const [section, setSection] = useState<SectionId>(() => {
    const hash = window.location.hash.slice(1);
    return NAV.some((n) => n.id === hash) ? (hash as SectionId) : "integrations";
  });
  // Which location layer actually answered, so the panel can say so rather than
  // implying a precision it doesn't have.
  const [locationSource, setLocationSource] = useState<string | null>(null);
  const weatherSource = locationSource ? LOCATION_SOURCE_LABEL[locationSource] : null;

  useEffect(() => {
    void window.agentIsland?.getWeather?.().then((w) => setLocationSource(w?.locationSource ?? null));
    return window.agentIsland?.onWeather?.((w) => setLocationSource(w?.locationSource ?? null));
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

  const active = NAV.find((n) => n.id === section) ?? NAV[0];

  return (
    <div className="settings">
      {/* The window chrome is macOS's own (hidden-inset title bar): real
          traffic lights, resize, zoom, full screen. These strips only make
          the top of the page draggable the way a title bar is. */}
      <div className="title-drag" aria-hidden />
      <aside className="s-sidebar">
        <div className="drag-strip" aria-hidden />
        <div className="s-brand">
          {/* A tiny island: the black pill with one of the crew in its wing. */}
          <span className="s-brand-pill" aria-hidden>
            <BotAvatar type="clover" size={12} seed={0.12} theme="dark" interactive={false} jumpEvery={0} />
          </span>
          <span className="s-brand-name">Agent Island</span>
        </div>
        <nav className="s-nav">
          {NAV.map((n) => (
            <button
              key={n.id}
              type="button"
              className={`s-nav-item${section === n.id ? " active" : ""}`}
              onClick={() => setSection(n.id)}
            >
              <span className="s-tile" style={{ "--tile": n.tile } as CSSProperties} aria-hidden>
                <Icon name={n.icon} size={12} />
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
        {/* Keyed on the section so each switch plays the short fade-in. */}
        <div className="s-page" key={section}>
        <header className="s-head">
          <span className="s-tile s-tile-lg" style={{ "--tile": active.tile } as CSSProperties} aria-hidden>
            <Icon name={active.icon} size={20} />
          </span>
          <div>
            <h1>{active.label}</h1>
            <p>{SECTION_BLURB[section]}</p>
          </div>
        </header>

        {section === "intelligence" && (() => {
          const status = assistantStatus(state.assistantSupport, state.assistantReason, state.assistantModel);
          return (
            <>
              <div className={`s-status ${status.tone}`}>
                <i aria-hidden />
                <span>{status.text}</span>
              </div>
              <div className="s-group">
                <Row
                  title="Assistant"
                  detail="The Ask bar: the bots when the island is empty, ✦ while agents work."
                  on={state.assistant}
                  onChange={(v) => set("assistant", v)}
                />
                <Row
                  title="Apple Intelligence"
                  detail="Use the on-device model for answers and multi-step actions. Off keeps simple commands only."
                  on={state.assistantModel}
                  onChange={(v) => set("assistantModel", v)}
                />
                <Row
                  title="Edge glow"
                  detail="A soft silver pulse inside the island's edge while the assistant is open."
                  on={state.edgeGlow}
                  onChange={(v) => set("edgeGlow", v)}
                />
                <Row
                  title="Say hello"
                  detail="A greeting from the bots when the island starts and when you come back to your Mac, written on-device."
                  on={state.greeting}
                  onChange={(v) => set("greeting", v)}
                />
              </div>
              <h2 className="s-sub-h">Voice</h2>
              <div className="s-group">
                <Row
                  title="Voice mode"
                  detail="A mic in the Ask bar. Speech is transcribed on this Mac; nothing is recorded."
                  on={state.voice}
                  onChange={(v) => set("voice", v)}
                />
                <Row
                  title="Speak answers"
                  detail="Read the answer aloud in Siri's voice when you asked by voice."
                  on={state.speakReplies}
                  onChange={(v) => set("speakReplies", v)}
                />
              </div>
            </>
          );
        })()}

        {section === "integrations" && (
          <div className="s-group">
            <Row
              icon={<ClaudeSprite live />}
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
            <Row
              title="Liquid Glass panel"
              detail={
                state.glassSupport === "native"
                  ? "Off: the island is one solid deep-black body. On: the panel below the notch becomes real macOS glass that refracts your wallpaper (the band stays black); the native sheet trails the open animation by a frame. Reduce transparency and Increase contrast switch it off automatically."
                  : state.glassSupport === "vibrancy"
                    ? "Off: the island is one solid deep-black body. On: real see-through blur beneath the panel. macOS 26 adds Liquid Glass refraction to this."
                    : "Unavailable on this install — the native helper wasn't built, so the island stays a solid black body."
              }
              on={state.glass && state.glassSupport !== "none"}
              onChange={(v) => set("glass", v)}
            />
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
            <div className="s-row">
              <div className="s-text">
                <b>Sessions</b>
                <span>
                  {state.sessionView === "compact"
                    ? "Each session is a small avatar bubble; hover one for what it's doing, click to jump."
                    : "Full rows: project, activity, model, host app and CPU/memory for every session."}
                </span>
              </div>
              <Segmented
                label="Show sessions as"
                value={state.sessionView}
                options={SESSION_VIEWS}
                onChange={(v) => set("sessionView", v)}
              />
            </div>
          </div>
        )}

        {section === "sounds" && (
          <>
          <div className="s-group">
            <Row
              title="Sound effects"
              detail="Chimes when agents finish, ask, need you — and when you allow."
              on={state.sounds}
              onChange={(v) => set("sounds", v)}
            />
          </div>
          <h2 className="s-sub-h">Theme</h2>
          <div className="s-themes" role="radiogroup" aria-label="Sound theme">
            {SOUND_THEMES.map((t) => (
              <div
                key={t}
                role="radio"
                aria-checked={state.soundTheme === t}
                tabIndex={0}
                className={`s-theme${state.soundTheme === t ? " on" : ""}`}
                onClick={() => {
                  set("soundTheme", t);
                  previewSound("success", t);
                }}
                onKeyDown={(e) => {
                  if (e.key !== "Enter" && e.key !== " ") return;
                  e.preventDefault();
                  set("soundTheme", t);
                  previewSound("success", t);
                }}
              >
                <b>{THEME_LABELS[t]}</b>
                <span>{THEME_BLURBS[t]}</span>
                <button
                  type="button"
                  className="s-play"
                  title={`Preview ${THEME_LABELS[t]}`}
                  aria-label={`Preview ${THEME_LABELS[t]}`}
                  onClick={(e) => {
                    e.stopPropagation();
                    previewSound("success", t);
                  }}
                >
                  <Icon name="play" size={11} />
                </button>
              </div>
            ))}
          </div>
          <h2 className="s-sub-h">Per event</h2>
          <div className="s-group">
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
                    <Icon name="play" size={11} />
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
          </>
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

        {section === "live" && (
          <div className="s-group">
            <Row
              title="Battery"
              detail="A moment in the notch when the charger comes or goes, and a small red battery under 20%. Nothing on desktop Macs."
              on={state.battery}
              onChange={(v) => set("battery", v)}
            />
            <Row
              title="Agent resource meter"
              detail="CPU and memory per session, summed over the agent's whole process tree. Sampled only while the island is open."
              on={state.procStats}
              onChange={(v) => set("procStats", v)}
            />
            <Row
              title="Quiet during Focus"
              detail="Mutes sounds and notification taps while a Focus is on. Approvals and questions still open the island."
              on={state.respectFocus}
              onChange={(v) => set("respectFocus", v)}
            />
            <div className="s-row s-sub">
              <div className="s-text">
                <b>Focus status</b>
                <span>
                  {state.focus.active
                    ? `On — ${state.focus.name ?? "Focus"}, since ${new Date(state.focus.since).toLocaleTimeString([], { hour: "numeric", minute: "2-digit" })}. If it stayed on by mistake, click the ☾ chip in the island.`
                    : "Off, or no signal yet. macOS keeps Focus state private, so a Shortcuts automation tells Agent Island instead — two links, set up once."}
                </span>
              </div>
              <button
                type="button"
                className="s-import"
                onClick={() => window.agentIsland?.settings?.openShortcuts?.()}
              >
                Open Shortcuts
              </button>
            </div>
            <div className="s-row s-sub">
              <div className="s-text">
                <span>
                  In Shortcuts: Automation → New → Focus → choose the Focus → <b>When turning on</b> →
                  Run immediately → add the action <b>Open URLs</b> with the first link below. Repeat with{" "}
                  <b>When turning off</b> and the second link. One pair per Focus you use.
                  {state.deepLinksRegistered
                    ? ""
                    : " Links register the first time the installed app runs (not from a dev build)."}
                </span>
              </div>
            </div>
            <LinkRow label="Focus turned on" url={state.focusLinks.on} />
            <LinkRow label="Focus turned off" url={state.focusLinks.off} />
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
              detail={
                state.loginNeedsApproval
                  ? "Requested — macOS wants your approval first: System Settings → General → Login Items & Extensions."
                  : "Start silently with your Mac — no Dock, no windows."
              }
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
        </div>
      </main>
    </div>
  );
}

createRoot(document.getElementById("root")!).render(
  <StrictMode>
    <Settings />
  </StrictMode>,
);
