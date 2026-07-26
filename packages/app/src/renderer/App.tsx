import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import type { AgentUsage, SessionSnapshot } from "@agent-island/shared";
import { SessionRow } from "./SessionRow";
import { ApprovalCard } from "./ApprovalCard";
import { QuestionCard } from "./QuestionCard";
import { PixelSprite } from "./PixelSprite";
import { OpenAiSprite } from "./OpenAiSprite";
import { CursorSprite } from "./CursorSprite";
import { PacFeast } from "./PacFeast";
import { UsageFooter } from "./UsageFooter";
import { playSound } from "./sounds";
import { DEFAULT_SOUND_PREFS, type SoundPrefs, type SoundTheme } from "./sound-prefs";
import { summarizeTransitions, useAnnouncer, useFocusTrap } from "./a11y";
import { clampIslandWidth, isSignificantChange, minIslandWidth } from "./island-width";
import { WeatherScene, type WeatherCondition } from "./weather/WeatherScene";

const ACTIVE_STATES = new Set(["working", "starting", "waiting-for-approval"]);
const MAX_ROWS = 5;

/** Discrete moments the edge spark reacts to — each gets its own color/pattern. */
type PulseKind = "done" | "failed" | "attention" | "question" | "approve";

/** Wing order: one sprite per agent kind that has sessions. */
const AGENT_SPRITES = [
  { kind: "claude-code", Sprite: PixelSprite },
  { kind: "codex", Sprite: OpenAiSprite },
  { kind: "cursor", Sprite: CursorSprite },
] as const;

export function App() {
  const [sessions, setSessions] = useState<SessionSnapshot[]>([]);
  const [usage, setUsage] = useState<AgentUsage[]>([]);
  const [connected, setConnected] = useState(false);
  const [hovering, setHovering] = useState(false);
  const [pinned, setPinned] = useState(false);
  const [now, setNow] = useState(() => Date.now());
  const [promptText, setPromptText] = useState("");
  const [promptFocused, setPromptFocused] = useState(false);
  // The prompt bar is not permanent furniture: it appears when an agent is
  // actually waiting on an answer, or when you deliberately open it.
  const [promptOpen, setPromptOpen] = useState(false);
  const promptInputRef = useRef<HTMLInputElement>(null);
  // Set when a send was dropped for lack of Accessibility — shows a hint.
  const [needsAccess, setNeedsAccess] = useState(false);
  // One-shot edge-spark burst; `n` retriggers the CSS animation on repeats.
  const [pulse, setPulse] = useState<{ kind: PulseKind; n: number } | null>(null);
  const pulseSeq = useRef(0);
  const firePulse = useCallback((kind: PulseKind) => {
    pulseSeq.current += 1;
    setPulse({ kind, n: pulseSeq.current });
  }, []);

  const islandRef = useRef<HTMLDivElement>(null);
  const panelRef = useRef<HTMLDivElement>(null);
  const measureRef = useRef<HTMLDivElement>(null);
  const interactiveRef = useRef(false);
  // VoiceOver reached in via the global shortcut; holds the panel open and traps Tab.
  const [a11yFocused, setA11yFocused] = useState(false);
  const { polite, assertive, announce } = useAnnouncer();
  // Widest the island may grow on this display, from main.
  const [maxIslandWidth, setMaxIslandWidth] = useState(720);
  const [notchWidth, setNotchWidth] = useState(196);
  const [weather, setWeather] = useState<{
    condition: string;
    temperature: string;
    summary: string;
    stale: boolean;
  } | null>(null);
  const [sound, setSound] = useState<SoundPrefs>(DEFAULT_SOUND_PREFS);
  // Mirror for once-registered listeners (chimes) that must not go stale.
  const soundRef = useRef<SoundPrefs>(DEFAULT_SOUND_PREFS);
  const [update, setUpdate] = useState<{ version: string } | null>(null);
  const prevStates = useRef<Map<
    string,
    { state: string; needsAction: boolean; hasQuestion: boolean }
  > | null>(null);

  const pending = useMemo(() => sessions.filter((s) => s.pending_approval), [sessions]);
  const asking = useMemo(() => sessions.filter((s) => s.pending_question), [sessions]);
  const needsYou = useMemo(
    () => sessions.filter((s) => s.state === "waiting-for-approval"),
    [sessions],
  );
  // Anything waiting on the human forces the panel open automatically.
  // Typing a prompt keeps it open even if the cursor drifts off the window.
  const expanded =
    hovering ||
    pinned ||
    promptFocused ||
    a11yFocused ||
    pending.length > 0 ||
    asking.length > 0 ||
    needsYou.length > 0;

  // Subscribe to session state from the main process.
  useEffect(() => {
    void window.agentIsland.getSessions().then((p) => {
      setSessions(p.sessions);
      setConnected(p.connected);
    });
    const offSessions = window.agentIsland.onSessions((p) => {
      setSessions(p.sessions);
      setConnected(p.connected);
    });
    const offToggle = window.agentIsland.onToggle(() => setPinned((v) => !v));
    void window.agentIsland.getUsage().then(setUsage);
    const offUsage = window.agentIsland.onUsage(setUsage);
    return () => {
      offSessions();
      offToggle();
      offUsage();
    };
  }, []);

  useEffect(() => {
    if (!expanded) return;
    setNow(Date.now());
    const id = window.setInterval(() => setNow(Date.now()), 1000);
    return () => window.clearInterval(id);
  }, [expanded]);

  // Bulletproof auto-collapse: main watches the real cursor while we're
  // interactive and tells us the moment it leaves the window.
  useEffect(() => {
    return window.agentIsland.onCursorLeft(() => setHovering(false));
  }, []);

  // Freeze animations while the Mac is locked/asleep (battery); resume on wake.
  // Optional-chained so an older preload (mid dev-reload) can never crash render.
  const [animated, setAnimated] = useState(true);
  useEffect(() => window.agentIsland.onAnimationActive?.(setAnimated), []);

  // Sound prefs (on/off, theme, per-event overrides) live in main.
  useEffect(() => {
    const apply = (p: {
      on: boolean;
      theme: string;
      overrides: Record<string, string>;
      custom?: Record<string, string>;
    }) => {
      const prefs: SoundPrefs = {
        on: p.on,
        theme: p.theme as SoundTheme,
        overrides: p.overrides as SoundPrefs["overrides"],
        custom: (p.custom ?? {}) as SoundPrefs["custom"],
      };
      soundRef.current = prefs;
      setSound(prefs);
    };
    void window.agentIsland.getSounds().then(apply);
    return window.agentIsland.onSounds(apply);
  }, []);

  // A dropped-for-Accessibility send flips on a hint; a successful send clears it.
  useEffect(
    () =>
      window.agentIsland.onPromptStatus((status) => {
        if (status === "no-accessibility") setNeedsAccess(true);
        else if (status === "sent") setNeedsAccess(false);
      }),
    [],
  );

  // A newer release exists — surface a quiet chip in the panel footer.
  useEffect(() => window.agentIsland.onUpdate(setUpdate), []);

  // One-shot chimes pushed by main (allowing an approval, answering a question).
  useEffect(() => {
    return window.agentIsland.onChime((event) => {
      if (event === "approve") {
        playSound("approve", soundRef.current);
        firePulse("approve");
      }
    });
  }, [firePulse]);

  // Alerts on state transitions: done -> success, failure -> fail, question ->
  // question chime, other needs-you -> attention. Each transition also fires an
  // edge-spark burst (independent of the sound preference). The first snapshot
  // only primes the map so relaunching the app never replays history.
  useEffect(() => {
    const next = new Map(
      sessions.map((s) => [
        s.key,
        {
          state: s.state,
          needsAction: s.requires_action || s.pending_approval !== null,
          hasQuestion: s.pending_question !== null,
        },
      ]),
    );
    const prev = prevStates.current;
    prevStates.current = next;
    if (!prev) return;

    const counts = { done: 0, failed: 0, questions: 0, actions: 0, only: "" };

    for (const [key, cur] of next) {
      const was = prev.get(key);
      if (!was) continue; // brand-new session: no alert until it transitions
      const becameDone = cur.state !== was.state && cur.state === "done";
      const becameFailed = cur.state !== was.state && cur.state === "failed";
      const newQuestion = cur.hasQuestion && !was.hasQuestion;
      const newAction = cur.needsAction && !was.needsAction;

      // Sound: unchanged behavior, still gated on the sound preference.
      if (sound.on) {
        if (becameDone) playSound("success", sound);
        if (newQuestion) playSound("question", sound);
        else if (newAction) playSound("attention", sound);
      }

      // Spark: always fires. One burst per session; done/failed win over
      // needs-you cues when several land in the same snapshot.
      if (becameDone) firePulse("done");
      else if (becameFailed) firePulse("failed");
      else if (newQuestion) firePulse("question");
      else if (newAction) firePulse("attention");

      // Haptics: the same events, felt instead of heard. Every applicable
      // pattern is requested and main picks the most urgent — which is also
      // what collapses a ten-session snapshot into a single pulse.
      if (becameDone) window.agentIsland.haptic?.("success");
      if (becameFailed) window.agentIsland.haptic?.("failure");
      if (newQuestion) window.agentIsland.haptic?.("inquiry");
      if (newAction) window.agentIsland.haptic?.("attention");

      if (becameDone) counts.done += 1;
      if (becameFailed) counts.failed += 1;
      if (newQuestion) counts.questions += 1;
      if (newAction) counts.actions += 1;
      if (becameDone || becameFailed || newQuestion || newAction) {
        const cwd = sessions.find((s) => s.key === key)?.cwd ?? "";
        counts.only = cwd.split("/").filter(Boolean).pop() ?? "";
      }
    }

    // One spoken sentence per snapshot, not one per session.
    const summary = summarizeTransitions(counts);
    if (summary) announce(summary.message, summary.urgency);
  }, [sessions, sound, firePulse, announce]);

  // Notch geometry, measured by main: the black body spans the band height so
  // the shape merges with the hardware notch, and every island width derives
  // from the real notch width — so the same build hugs a 14" Pro or a 13" Air.
  useEffect(() => {
    const apply = (l: { inset: number; notchWidth: number; maxIslandWidth?: number }) => {
      document.documentElement.style.setProperty("--notch-inset", `${l.inset}px`);
      if (l.notchWidth > 0) {
        document.documentElement.style.setProperty("--notch-width", `${l.notchWidth}px`);
        setNotchWidth(l.notchWidth);
      }
      // Optional-chained: an older preload mid dev-reload won't send it.
      if (l.maxIslandWidth && l.maxIslandWidth > 0) {
        setMaxIslandWidth(l.maxIslandWidth);
        // Also caps .panel-measure, so over-long strings ellipsise instead of
        // asking for an island wider than the display.
        document.documentElement.style.setProperty("--island-max", `${l.maxIslandWidth}px`);
      }
    };
    void window.agentIsland.getLayout().then(apply);
    return window.agentIsland.onLayout(apply);
  }, []);

  // Text scale (our stand-in for Dynamic Type, which macOS doesn't expose).
  useEffect(() => {
    const apply = (p: { textSize: string }) =>
      document.documentElement.setAttribute("data-text-size", p.textSize);
    void window.agentIsland.getUiPrefs?.().then(apply);
    return window.agentIsland.onUiPrefs?.(apply);
  }, []);

  // Local weather (off unless the user enabled it).
  useEffect(() => {
    void window.agentIsland.getWeather?.().then((w) => setWeather(w ?? null));
    return window.agentIsland.onWeather?.((w) => setWeather(w ?? null));
  }, []);

  // VoiceOver reach-in from the global shortcut.
  useEffect(() => window.agentIsland.onA11yFocus?.(setA11yFocused), []);
  const releaseA11yFocus = useCallback(() => window.agentIsland.releaseA11yFocus?.(), []);
  useFocusTrap(panelRef, a11yFocused, releaseA11yFocus);

  /**
   * Grow the island to fit its content. `.panel-measure` is `width: max-content`
   * so it reports the panel's natural width independent of the island's current
   * width — without that decoupling this feeds itself and oscillates.
   */
  useEffect(() => {
    const target = measureRef.current;
    if (!target || !expanded) return;

    let frame = 0;
    let applied = 0;
    const measure = () => {
      frame = 0;
      const next = clampIslandWidth(
        target.scrollWidth,
        minIslandWidth(notchWidth),
        maxIslandWidth,
      );
      // Sub-pixel churn from font rendering would thrash the transition.
      if (!isSignificantChange(applied, next)) return;
      applied = next;
      document.documentElement.style.setProperty("--island-w", `${next}px`);
    };

    const observer = new ResizeObserver(() => {
      if (frame === 0) frame = requestAnimationFrame(measure);
    });
    observer.observe(target);
    measure();
    return () => {
      observer.disconnect();
      if (frame !== 0) cancelAnimationFrame(frame);
    };
  }, [expanded, notchWidth, maxIslandWidth]);

  // Main polls the cursor against the ISLAND, not the window — the window is
  // far wider, so it needs to know where the pill actually is.
  useEffect(() => {
    const report = () => {
      const el = islandRef.current;
      if (!el) return;
      const r = el.getBoundingClientRect();
      window.agentIsland.reportIslandRect?.({
        x: Math.round(r.left),
        y: Math.round(r.top),
        width: Math.round(r.width),
        height: Math.round(r.height),
      });
    };
    report();
    // The rect changes as the island expands and as its width settles.
    const id = window.setInterval(report, 300);
    return () => window.clearInterval(id);
  }, []);

  // The window is click-through with forwarded mouse-move; detect when the
  // pointer is over the island and expand. Leaving collapses (unless pinned).
  useEffect(() => {
    const onMove = (e: MouseEvent) => {
      const el = islandRef.current;
      if (!el) return;
      const r = el.getBoundingClientRect();
      const inside =
        e.clientX >= r.left && e.clientX <= r.right && e.clientY >= r.top && e.clientY <= r.bottom;
      setHovering(inside);
    };
    const onLeave = () => setHovering(false);
    window.addEventListener("mousemove", onMove);
    document.addEventListener("mouseleave", onLeave);
    return () => {
      window.removeEventListener("mousemove", onMove);
      document.removeEventListener("mouseleave", onLeave);
    };
  }, []);

  // Capture the mouse only while expanded so the rest of the desktop stays clickable.
  useEffect(() => {
    if (expanded !== interactiveRef.current) {
      interactiveRef.current = expanded;
      window.agentIsland.setInteractive(expanded);
    }
  }, [expanded]);

  const active = useMemo(() => sessions.filter((s) => ACTIVE_STATES.has(s.state)), [sessions]);
  const visible = useMemo(() => sessions.slice(0, MAX_ROWS), [sessions]);
  const dominant = pending[0] ?? active[0] ?? sessions[0] ?? null;
  const stateCls = dominant ? `state-${dominant.state}` : connected ? "idle" : "offline";

  // Free-form prompts go to the top/active session (the first running one, else
  // the first in the list).
  const promptTarget = active[0] ?? sessions[0] ?? null;
  const submitPrompt = () => {
    const text = promptText.trim();
    if (!text || !promptTarget) return;
    window.agentIsland.sendPrompt(promptTarget, text);
    setPromptText("");
  };

  /**
   * When the prompt bar is visible. An agent waiting on a question gets it
   * automatically — that's the moment you actually need to type. Otherwise it
   * stays out of the way until you ask for it, and never disappears from under
   * you mid-sentence.
   */
  const showPrompt =
    promptTarget !== null && (promptOpen || promptFocused || asking.length > 0 || promptText !== "");

  const togglePrompt = () => {
    window.agentIsland.haptic?.("tick");
    setPromptOpen((open) => {
      if (open) {
        setPromptText("");
        promptInputRef.current?.blur();
        return false;
      }
      // Focus once it has actually rendered.
      requestAnimationFrame(() => promptInputRef.current?.focus());
      return true;
    });
  };

  // Sprites are strictly live: one per agent kind that is ACTIVELY running
  // (working / starting / waiting). Nothing running = an empty wing.
  const liveKinds = new Set(active.map((s) => s.agent));
  const shown = AGENT_SPRITES.filter((a) => liveKinds.has(a.kind));
  // Active agent kinds in stable order — these become Pac's dots.
  const activeKinds = shown.map((a) => a.kind);

  // The compact working animation is Pac-Man chomping a line of agent logos
  // (crab / blossom / cube) like dots — it takes over the whole sprite wing
  // while work is live. Events are signalled separately by the edge glow.
  const showFeast = !expanded && active.length > 0;
  // At rest — sessions present but nothing running — the rim carries a very soft
  // green-bluish breathing glow.
  const showGlow = !expanded && sessions.length > 0 && active.length === 0;

  // Weather fills the collapsed island only when no agent is working: agents
  // always preempt it, so it never competes with the thing you're waiting on.
  // Note this replaces the previously INVISIBLE resting state — with weather on,
  // the island is always at least a small live scene.
  const ambientWeather = weather !== null && !expanded && active.length === 0;
  const condition = (weather?.condition ?? "clear-day") as WeatherCondition;

  return (
    <div className={`app${animated ? "" : " paused"}${a11yFocused ? " a11y-focus" : ""}`}>
      {/* Spoken, never drawn. Two urgencies because a blocked agent can't wait
          for a gap in speech and a finished one can. */}
      <div className="sr-only" role="status" aria-live="polite">
        {polite}
      </div>
      <div className="sr-only" role="alert" aria-live="assertive">
        {assertive}
      </div>
      <div ref={islandRef} className="island-wrap">
        {(sessions.length > 0 || expanded) && (
          <>
            <i className="ear ear-l" aria-hidden />
            <i className="ear ear-r" aria-hidden />
          </>
        )}
        <div
          className={`island ${stateCls}${expanded ? " expanded" : ""}${
            sessions.length === 0 && !ambientWeather ? " bare" : ""
          }${showFeast ? " has-pac" : ""}${ambientWeather ? " has-weather" : ""} spr-${
            showFeast ? 0 : shown.length
          }`}
          role="region"
          aria-label="Agent Island"
        >
          {showGlow && <div className="notch-glow" aria-hidden />}
          {pulse && (
            <div
              className="edge-spark"
              data-fx={pulse.kind}
              key={pulse.n}
              aria-hidden
              onAnimationEnd={() => setPulse(null)}
            />
          )}
          <div className={`notch-spacer ${stateCls}`}>
            <span className="sprites">
              {showFeast ? (
                <PacFeast kinds={activeKinds} />
              ) : ambientWeather ? (
                <WeatherScene condition={condition} variant="ambient" />
              ) : (
                shown.map(({ kind, Sprite }) => <Sprite key={kind} live />)
              )}
            </span>
            <span
              className="spacer-info"
              aria-label={
                needsYou.length > 0
                  ? `${needsYou.length} sessions need attention`
                  : ambientWeather
                    ? weather?.summary
                    : `${active.length} active sessions`
              }
            >
              {needsYou.length > 0
                ? `${needsYou.length}!`
                : active.length > 0
                  ? active.length
                  : ambientWeather
                    ? weather?.temperature
                    : ""}
            </span>
          </div>

          <div className="panel-wrap">
            <div className="panel" ref={panelRef}>
              {/* `max-content` here is what makes the island content-sized: it
                  reports the panel's natural width independent of the width the
                  island currently has, so the measurement can't feed itself. */}
              <div className="panel-measure" ref={measureRef}>
              {pending.map((s) => (
                <ApprovalCard
                  key={`ap-${s.key}`}
                  session={s}
                  onDecide={(id, decision) => window.agentIsland.approve(id, decision)}
                />
              ))}
              {asking.map((s) => (
                <QuestionCard
                  key={`q-${s.pending_question?.id ?? s.key}`}
                  session={s}
                  onJump={(sess) => window.agentIsland.jump(sess)}
                  onAnswer={(sess, options) => window.agentIsland.answer(sess, options)}
                />
              ))}
              <ul className="rows">
                {visible.map((s) => (
                  <SessionRow
                    key={s.key}
                    session={s}
                    now={now}
                    onJump={(sess) => window.agentIsland.jump(sess)}
                  />
                ))}
                {visible.length === 0 && (
                  <li className="empty">{connected ? "no sessions" : "offline"}</li>
                )}
              </ul>
              {weather && (
                <div className="weather-card">
                  <WeatherScene condition={condition} variant="card" />
                  {/* The scene is decorative; this text is the whole meaning of
                      it for anyone using VoiceOver. */}
                  <span className="weather-text">
                    <b>{weather.temperature}</b>
                    <span>
                      {weather.summary}
                      {weather.stale ? " · offline" : ""}
                    </span>
                  </span>
                </div>
              )}
              <UsageFooter usage={usage} />
              {showPrompt && (
                <form
                  className="prompt-bar"
                  onSubmit={(e) => {
                    e.preventDefault();
                    submitPrompt();
                  }}
                >
                  <input
                    ref={promptInputRef}
                    className="prompt-input"
                    type="text"
                    value={promptText}
                    placeholder={
                      asking.length > 0
                        ? "Reply to the agent…"
                        : promptTarget?.agent === "cursor"
                          ? "Ask Cursor…"
                          : "Ask the agent…"
                    }
                    aria-label={
                      promptTarget?.agent === "cursor"
                        ? "Send a prompt to Cursor"
                        : "Send a prompt to the agent"
                    }
                    spellCheck={false}
                    autoFocus={promptOpen}
                    onChange={(e) => setPromptText(e.target.value)}
                    onFocus={() => {
                      setPromptFocused(true);
                      window.agentIsland.setPromptComposing(true);
                    }}
                    onBlur={() => {
                      setPromptFocused(false);
                      window.agentIsland.setPromptComposing(false);
                    }}
                    onClick={(e) => e.stopPropagation()}
                    onKeyDown={(e) => {
                      if (e.key === "Escape") {
                        setPromptText("");
                        setPromptOpen(false);
                        e.currentTarget.blur();
                      }
                    }}
                  />
                  <button
                    className="ctl icon prompt-send"
                    type="submit"
                    title="Send prompt"
                    aria-label="Send prompt"
                    disabled={!promptText.trim()}
                    onClick={(e) => e.stopPropagation()}
                  >
                    ↵
                  </button>
                </form>
              )}
              {showPrompt && needsAccess && (
                <button
                  type="button"
                  className="prompt-hint"
                  title="Agent Island needs Accessibility to type into Cursor's Composer or your terminal. App updates invalidate an existing grant even when the toggle still shows on — clicking refreshes our entry; tick Agent Island in the list that opens."
                  onClick={(e) => {
                    e.stopPropagation();
                    window.agentIsland.openAccessibility();
                  }}
                >
                  ⚠ Grant Accessibility to send prompts →
                </button>
              )}
              <div className="panel-controls">
                <span className="ctl-cluster">
                  <button
                    className={`ctl icon${sound.on ? "" : " off"}`}
                    title={sound.on ? "Sound on" : "Sound off"}
                    aria-label={sound.on ? "Sound on" : "Sound off"}
                    aria-pressed={sound.on}
                    onClick={(e) => {
                      e.stopPropagation();
                      window.agentIsland.haptic?.("tick");
                      window.agentIsland.setSounds(!sound.on);
                    }}
                  >
                    ♪
                  </button>
                  {promptTarget && (
                    <button
                      className={`ctl icon prompt-toggle${promptOpen ? " on" : ""}`}
                      title={promptOpen ? "Close the prompt" : "Send a prompt to the agent"}
                      aria-label={promptOpen ? "Close the prompt" : "Send a prompt to the agent"}
                      aria-expanded={showPrompt}
                      onClick={(e) => {
                        e.stopPropagation();
                        togglePrompt();
                      }}
                    >
                      ✎
                    </button>
                  )}
                </span>
                {update ? (
                  <button
                    className="ctl update"
                    title={`Download Agent Island ${update.version}`}
                    onClick={(e) => {
                      e.stopPropagation();
                      window.agentIsland.haptic?.("tick");
                      window.agentIsland.openUpdate();
                    }}
                  >
                    ↑ update {update.version}
                  </button>
                ) : null}
                <span className="ctl-cluster">
                  <button
                    className="ctl icon"
                    title="Settings"
                    aria-label="Settings"
                    onClick={(e) => {
                      e.stopPropagation();
                      window.agentIsland.haptic?.("tick");
                      window.agentIsland.openSettings();
                    }}
                  >
                    ⚙
                  </button>
                  <button
                    className="ctl icon quit"
                    title="Quit"
                    aria-label="Quit"
                    onClick={(e) => {
                      e.stopPropagation();
                      window.agentIsland.haptic?.("tick");
                      window.agentIsland.quit();
                    }}
                  >
                    ⏻
                  </button>
                </span>
              </div>
              </div>
            </div>
          </div>
        </div>
      </div>
    </div>
  );
}
