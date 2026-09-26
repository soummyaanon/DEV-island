import { useCallback, useEffect, useMemo, useRef, useState, type CSSProperties } from "react";
import type { AgentUsage, SessionSnapshot } from "@agent-island/shared";
import { SessionRow } from "./SessionRow";
import { SessionBubble } from "./SessionBubble";
import { ApprovalCard } from "./ApprovalCard";
import { QuestionCard } from "./QuestionCard";
import { AGENT_LOOK, AgentAvatar, AgentOrb, STATE_TINT, orbState } from "./agent-avatar";
import { AssistantBar } from "./AssistantBar";
import { BotCrew } from "./BotCrew";
import { GreetingCard, greetingDuration } from "./GreetingCard";
import { IdleCrew } from "./IdleCrew";
import { WorkCrew } from "./WorkCrew";
import { IslandGlow } from "./IslandGlow";
import { FieldBeam } from "./FieldBeam";
import { assistantUnavailableReason } from "./assistant-context";
import { StatusFooter } from "./StatusFooter";
import { LIVE_ACTIVITY_MS, LiveActivity, type LiveActivityKind } from "./LiveActivity";
import { wingContent } from "./wing-priority";
import { Battery, Icon } from "./Icons";
import { playSound } from "./sounds";
import { DEFAULT_SOUND_PREFS, type SoundPrefs, type SoundTheme } from "./sound-prefs";
import { summarizeTransitions, useAnnouncer, useFocusTrap, useReducedMotion } from "./a11y";
import { OPEN_SPRING, SETTLE_SPRING, STEP_EASING, springEasing } from "./motion";
import { WheelGesture, fingerDelta } from "./gesture";
import { clampIslandWidth, isSignificantChange, minIslandWidth } from "./island-width";
import { WeatherScene, type WeatherCondition } from "./weather/WeatherScene";

const ACTIVE_STATES = new Set(["working", "starting", "waiting-for-approval"]);
const MAX_ROWS = 5;
/** Bubbles are small; more of them fit before the island gets wide. */
const MAX_BUBBLES = 8;

/** Discrete moments the edge spark reacts to — each gets its own color/pattern. */
type PulseKind = "done" | "failed" | "attention" | "question" | "approve" | "hello" | "charge";

/** Wing order: one thinking orb per agent kind that is working. */
const AGENT_ORDER = ["claude-code", "codex", "cursor"] as const;

/** How long a finished agent's avatar holds the wing. */
const MOMENT_MS = 3500;

export function App() {
  const [sessions, setSessions] = useState<SessionSnapshot[]>([]);
  const [usage, setUsage] = useState<AgentUsage[]>([]);
  const [connected, setConnected] = useState(false);
  const [hovering, setHovering] = useState(false);
  const [pinned, setPinned] = useState(false);
  // Gestures. `openWith` and `naturalScroll` come from main's ui-prefs.
  const [openWith, setOpenWith] = useState<"hover" | "swipe">("hover");
  const [naturalScroll, setNaturalScroll] = useState(true);
  // Compact bubbles (default) or the full rows.
  const [sessionView, setSessionView] = useState<"compact" | "detailed">("compact");
  // Intelligence switches from Settings.
  const [aiPrefs, setAiPrefs] = useState({ assistant: true, voice: true, speakReplies: true, edgeGlow: true });
  // Swipe mode: a swipe-down (or wing click) happened while hovering.
  const [gestureOpen, setGestureOpen] = useState(false);
  // Swipe-up while open: stay closed until the pointer leaves the island.
  const [dismissed, setDismissed] = useState(false);
  // −1..1 rubber-band fraction while a swipe accumulates; 0 at rest.
  const [rubber, setRubber] = useState(0);
  const gesture = useRef(new WheelGesture());
  const rubberTimer = useRef<number | null>(null);
  const [now, setNow] = useState(() => Date.now());
  const [promptText, setPromptText] = useState("");
  const [promptFocused, setPromptFocused] = useState(false);
  // The prompt bar is not permanent furniture: it appears when an agent is
  // actually waiting on an answer, or when you deliberately open it.
  const [promptOpen, setPromptOpen] = useState(false);
  // Apple Intelligence Ask bar: whether the sidecar's on-device model can
  // answer, whether the bar is open, and whether its input holds focus.
  const [assistantSupport, setAssistantSupport] = useState("no-helper");
  const [assistantOpen, setAssistantOpen] = useState(false);
  const [assistantFocused, setAssistantFocused] = useState(false);
  // An answer is streaming — the bot crew hops along with it.
  const [assistantLive, setAssistantLive] = useState(false);
  // The footer's left slot: text fields render into it (a portal for the Ask
  // bar), so a field is a small pill beside the icons, not a row of its own.
  const [fieldSlot, setFieldSlot] = useState<HTMLElement | null>(null);
  // A session that just finished or failed takes a bow in the wing.
  const [moment, setMoment] = useState<{ key: string; kind: "done" | "failed"; n: number } | null>(null);
  const momentSeq = useRef(0);
  const momentTimer = useRef<number | null>(null);
  const showMoment = useCallback((key: string, kind: "done" | "failed") => {
    momentSeq.current += 1;
    setMoment({ key, kind, n: momentSeq.current });
    if (momentTimer.current !== null) window.clearTimeout(momentTimer.current);
    momentTimer.current = window.setTimeout(() => setMoment(null), MOMENT_MS);
  }, []);
  // The hello at launch / after time away: the island drops open for a few
  // seconds with the bot crew and a line from the on-device model.
  const [greeting, setGreeting] = useState<{ title: string; line: string; ai: boolean; n: number } | null>(null);
  const greetSeq = useRef(0);
  const greetTimer = useRef<number | null>(null);
  const dismissGreeting = useCallback(() => {
    if (greetTimer.current !== null) window.clearTimeout(greetTimer.current);
    greetTimer.current = null;
    setGreeting(null);
  }, []);
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
  // The island body itself (not the wrap): the edge light traces its outline.
  const islandBodyRef = useRef<HTMLDivElement>(null);
  const panelRef = useRef<HTMLDivElement>(null);
  // The glass sheet follows this element, not the whole island.
  const panelWrapRef = useRef<HTMLDivElement>(null);
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
  // Live activities: battery, Focus, and the per-session resource meter.
  const [power, setPower] = useState<{
    percent: number;
    state: "charging" | "discharging" | "charged" | "ac";
    minutesRemaining: number | null;
    low: boolean;
  } | null>(null);
  const [focus, setFocus] = useState<{ active: boolean; name: string | null; mute: boolean } | null>(null);
  const [procStats, setProcStats] = useState<
    Record<string, { cpu: number; rssMb: number; procs: number } | null>
  >({});
  // A transient moment in the wing; `n` retriggers the CSS on repeats.
  const [activity, setActivity] = useState<{ kind: LiveActivityKind; percent: number; n: number } | null>(
    null,
  );
  const activitySeq = useRef(0);
  const activityTimer = useRef<number | null>(null);
  const showActivity = useCallback((kind: LiveActivityKind, percent = 0) => {
    activitySeq.current += 1;
    setActivity({ kind, percent, n: activitySeq.current });
    if (activityTimer.current !== null) window.clearTimeout(activityTimer.current);
    activityTimer.current = window.setTimeout(() => setActivity(null), LIVE_ACTIVITY_MS[kind]);
  }, []);
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
  // Leaving the island resets both gesture latches, so a gesture-opened island
  // can always be closed by moving away — never stuck open.
  useEffect(() => {
    if (hovering) return;
    setGestureOpen(false);
    setDismissed(false);
  }, [hovering]);

  // Hover opens the island in hover mode; in swipe mode it also needs a
  // swipe-down (or a wing click). A swipe-up parks it closed until you leave.
  const hoverExpands = hovering && !dismissed && (openWith === "hover" || gestureOpen);
  // Anything waiting on the human forces the panel open automatically.
  // Typing a prompt keeps it open even if the cursor drifts off the window.
  const expanded =
    hoverExpands ||
    pinned ||
    promptFocused ||
    assistantFocused ||
    a11yFocused ||
    greeting !== null ||
    pending.length > 0 ||
    asking.length > 0 ||
    needsYou.length > 0;
  // Wheel events only reach a window that captures the mouse, so swipe mode
  // makes the collapsed wings interactive while the pointer is over them.
  const interactive = expanded || (openWith === "swipe" && hovering);

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

  // A focused prompt input holds the island open on purpose — but only while
  // it's worth holding: with nothing typed, leaving the island (or the window
  // losing focus) closes the bar, otherwise one click on ✎ pins the island open
  // until someone finds Escape.
  const promptTextRef = useRef("");
  promptTextRef.current = promptText;
  const closeEmptyPrompt = useCallback(() => {
    if (promptTextRef.current.trim() !== "") return;
    promptInputRef.current?.blur();
    setPromptFocused(false);
    setPromptOpen(false);
    window.agentIsland.setPromptComposing(false);
  }, []);
  useEffect(() => {
    if (!hovering) closeEmptyPrompt();
  }, [hovering, closeEmptyPrompt]);
  useEffect(() => {
    window.addEventListener("blur", closeEmptyPrompt);
    return () => window.removeEventListener("blur", closeEmptyPrompt);
  }, [closeEmptyPrompt]);

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

      // Sound: gated on the preference, and quiet while a Focus is on.
      if (sound.on && !focus?.mute) {
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

      if (becameDone) showMoment(key, "done");
      else if (becameFailed) showMoment(key, "failed");

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
  }, [sessions, sound, focus, firePulse, announce, showMoment]);

  // A timer the assistant set has ended: chime, bloom and say so.
  useEffect(
    () =>
      window.agentIsland.onAssistantTimer?.((label) => {
        playSound("success", soundRef.current);
        firePulse("done");
        announce(label ? `Timer done: ${label}` : "Timer done", "assertive");
      }),
    [firePulse, announce],
  );

  // Can the on-device model answer? The sidecar reports once at launch and
  // again if it changes (e.g. the model finishes downloading).
  useEffect(() => {
    void window.agentIsland.getAssistant?.().then(setAssistantSupport);
    return window.agentIsland.onAssistantSupport?.(setAssistantSupport);
  }, []);
  // The crew only shows where Apple Intelligence could ever work; on a Mac
  // that can't run it at all they'd be a door to nowhere.
  // Every Mac with the helper gets the assistant: the model where Apple
  // Intelligence runs, the command reader everywhere else.
  const crewAvailable = aiPrefs.assistant && (assistantSupport === "available" || assistantSupport === "basic");
  const setAssistantFocus = useCallback((focused: boolean) => {
    setAssistantFocused(focused);
    window.agentIsland.setPromptComposing(focused);
  }, []);

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

  // Presentation prefs from main: text scale (our stand-in for Dynamic Type)
  // and how the island opens.
  useEffect(() => {
    const apply = (p: {
      textSize: string;
      openWith?: string;
      naturalScroll?: boolean;
      glass?: string;
      sessionView?: string;
      assistant?: boolean;
      voice?: boolean;
      speakReplies?: boolean;
      edgeGlow?: boolean;
    }) => {
      setSessionView(p.sessionView === "detailed" ? "detailed" : "compact");
      setAiPrefs({
        assistant: p.assistant ?? true,
        voice: p.voice ?? true,
        speakReplies: p.speakReplies ?? true,
        edgeGlow: p.edgeGlow ?? true,
      });
      if (p.assistant === false) setAssistantOpen(false);
      document.documentElement.setAttribute("data-text-size", p.textSize);
      setOpenWith(p.openWith === "swipe" ? "swipe" : "hover");
      setNaturalScroll(p.naturalScroll ?? true);
      // Which material the panel should style for. Native/vibrancy = a real
      // glass sheet sits beneath the panel, so CSS draws only a scrim.
      document.documentElement.setAttribute("data-glass", p.glass ?? "css");
    };
    void window.agentIsland.getUiPrefs?.().then(apply);
    return window.agentIsland.onUiPrefs?.(apply);
  }, []);

  // Say hello: once at launch (asked for here, so it can't race the page
  // load), and whenever main pushes a welcome-back. Shown only, never spoken.
  useEffect(() => {
    const show = (g: { title: string; line: string; ai: boolean } | null) => {
      if (!g) return;
      greetSeq.current += 1;
      setGreeting({ ...g, n: greetSeq.current });
      firePulse("hello");
      window.agentIsland.haptic?.("success");
      if (greetTimer.current !== null) window.clearTimeout(greetTimer.current);
      greetTimer.current = window.setTimeout(() => {
        greetTimer.current = null;
        setGreeting(null);
      }, greetingDuration(g.line));
    };
    void window.agentIsland.getGreeting?.().then(show);
    return window.agentIsland.onGreeting?.(show);
  }, [firePulse]);

  // Spring motion: integrate once, publish as CSS timing functions. Reduced
  // Motion swaps both for a 1ms step so CSS and any JS timing agree.
  const reducedMotion = useReducedMotion();
  useEffect(() => {
    const open = reducedMotion ? STEP_EASING : springEasing(OPEN_SPRING);
    const settle = reducedMotion ? STEP_EASING : springEasing(SETTLE_SPRING);
    const root = document.documentElement.style;
    root.setProperty("--spring-open", open.easing);
    root.setProperty("--dur-open", `${open.ms}ms`);
    root.setProperty("--spring-settle", settle.easing);
    root.setProperty("--dur-settle", `${settle.ms}ms`);
  }, [reducedMotion]);

  // Once the open transition lands, further width changes use the firm spring.
  const [settled, setSettled] = useState(false);
  useEffect(() => {
    if (!expanded) setSettled(false);
  }, [expanded]);

  // Local weather (off unless the user enabled it).
  useEffect(() => {
    void window.agentIsland.getWeather?.().then((w) => setWeather(w ?? null));
    return window.agentIsland.onWeather?.((w) => setWeather(w ?? null));
  }, []);

  // Battery. The push that carries a plug/unplug transition becomes a moment
  // in the wing; crossing into low battery is one too.
  const prevLow = useRef(false);
  useEffect(() => {
    const apply = (
      p: {
        percent: number;
        state: string;
        minutesRemaining: number | null;
        event: string | null;
        low: boolean;
      } | null,
    ) => {
      if (!p) {
        setPower(null);
        prevLow.current = false;
        return;
      }
      setPower({
        percent: p.percent,
        state: p.state as "charging" | "discharging" | "charged" | "ac",
        minutesRemaining: p.minutesRemaining,
        low: p.low,
      });
      if (p.event === "plugged") {
        showActivity("battery-plugged", p.percent);
        // Electricity runs round the island's edge as the charger goes in.
        firePulse("charge");
      } else if (p.event === "unplugged") showActivity("battery-unplugged", p.percent);
      else if (p.low && !prevLow.current) showActivity("battery-low", p.percent);
      prevLow.current = p.low;
    };
    void window.agentIsland.getPower?.().then(apply);
    return window.agentIsland.onPower?.(apply);
  }, [showActivity]);

  // Focus, as told by the user's Shortcuts automation. A change is a moment too.
  const prevFocus = useRef<boolean | null>(null);
  useEffect(() => {
    const apply = (f: { active: boolean; name: string | null; mute: boolean }) => {
      setFocus({ active: f.active, name: f.name, mute: f.mute });
      if (prevFocus.current !== null && prevFocus.current !== f.active) {
        showActivity(f.active ? "focus-on" : "focus-off");
      }
      prevFocus.current = f.active;
    };
    void window.agentIsland.getFocus?.().then(apply);
    return window.agentIsland.onFocus?.(apply);
  }, [showActivity]);

  // Resource meter, pushed only while the panel is open.
  useEffect(() => window.agentIsland.onProcStats?.(setProcStats), []);

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
  // far wider, so it needs to know where the pill actually is. The glass sheet
  // follows the PANEL's rect. A ResizeObserver fires every frame while the
  // spring transitions run, so the glass tracks the motion one frame behind at
  // most; the slow heartbeat only covers anything the observer can't see.
  useEffect(() => {
    const rectOf = (el: HTMLElement | null) => {
      if (!el) return null;
      const r = el.getBoundingClientRect();
      return {
        x: Math.round(r.left),
        y: Math.round(r.top),
        width: Math.round(r.width),
        height: Math.round(r.height),
      };
    };
    let frame = 0;
    const report = () => {
      frame = 0;
      const island = rectOf(islandRef.current);
      if (!island) return;
      window.agentIsland.reportIslandRect?.(island, rectOf(panelWrapRef.current));
    };
    const schedule = () => {
      if (frame === 0) frame = requestAnimationFrame(report);
    };
    const observer = new ResizeObserver(schedule);
    if (islandRef.current) observer.observe(islandRef.current);
    if (panelWrapRef.current) observer.observe(panelWrapRef.current);
    report();
    const heartbeat = window.setInterval(report, 1000);
    return () => {
      observer.disconnect();
      window.clearInterval(heartbeat);
      if (frame !== 0) cancelAnimationFrame(frame);
    };
  }, []);

  // Reduce transparency / Increase contrast. CSS already follows both; main
  // also needs them, to retire the native glass sheet the moment they flip.
  useEffect(() => {
    const transparency = window.matchMedia("(prefers-reduced-transparency: reduce)");
    const contrast = window.matchMedia("(prefers-contrast: more)");
    const report = () =>
      window.agentIsland.reportMediaPrefs?.({
        reducedTransparency: transparency.matches,
        moreContrast: contrast.matches,
      });
    report();
    transparency.addEventListener("change", report);
    contrast.addEventListener("change", report);
    return () => {
      transparency.removeEventListener("change", report);
      contrast.removeEventListener("change", report);
    };
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

  // Two-finger swipes. Deltas are converted to FINGER motion first, so "down"
  // means the same thing whatever the natural-scrolling setting. Swipe up
  // over an open island closes it; in swipe mode, swipe down over the wings
  // opens it. Nothing fires while you're typing a prompt.
  useEffect(() => {
    const onWheel = (e: WheelEvent) => {
      if (promptFocused) return;
      const el = islandRef.current;
      if (!el) return;
      const r = el.getBoundingClientRect();
      const inside =
        e.clientX >= r.left && e.clientX <= r.right && e.clientY >= r.top && e.clientY <= r.bottom;
      if (!inside) return;
      const g = gesture.current;
      const direction = g.feed(fingerDelta(e.deltaY, naturalScroll), e.timeStamp);
      setRubber(g.progress(e.timeStamp));
      if (rubberTimer.current !== null) window.clearTimeout(rubberTimer.current);
      rubberTimer.current = window.setTimeout(() => setRubber(0), 200);
      if (direction === "up" && expanded) {
        setDismissed(true);
        setGestureOpen(false);
        window.agentIsland.haptic?.("tick");
      } else if (direction === "down" && !expanded && openWith === "swipe") {
        setGestureOpen(true);
        window.agentIsland.haptic?.("tick");
      }
    };
    window.addEventListener("wheel", onWheel, { passive: true });
    return () => {
      window.removeEventListener("wheel", onWheel);
      if (rubberTimer.current !== null) window.clearTimeout(rubberTimer.current);
    };
  }, [promptFocused, naturalScroll, expanded, openWith]);

  // Capture the mouse only while needed so the rest of the desktop stays clickable.
  // The reason travels along so main's log says WHY the island is open.
  const openReason = [
    hoverExpands && (gestureOpen ? "gesture" : "hover"),
    pinned && "pinned",
    promptFocused && "prompt",
    assistantFocused && "assistant",
    a11yFocused && "a11y",
    greeting !== null && "greeting",
    pending.length > 0 && "approval",
    asking.length > 0 && "question",
    needsYou.length > 0 && "needs-you",
    !expanded && hovering && "wings",
  ]
    .filter(Boolean)
    .join(",");
  useEffect(() => {
    if (interactive !== interactiveRef.current) {
      interactiveRef.current = interactive;
      window.agentIsland.setInteractive(interactive, openReason);
    }
  }, [interactive, openReason]);

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

  // Orbs are strictly live: one per agent kind that is ACTIVELY running
  // (working / starting / waiting), tinted in that agent's colour and animated
  // for what its most urgent session is doing. Nothing running = empty wing.
  const shown = AGENT_ORDER.flatMap((kind) => {
    const mine = active.filter((s) => s.agent === kind);
    if (mine.length === 0) return [];
    const lead = mine.find((s) => s.state === "waiting-for-approval") ?? mine[0];
    const tint = lead.state === "waiting-for-approval" ? STATE_TINT[lead.state] : AGENT_LOOK[kind].color;
    return [{ kind, state: orbState(lead), tint }];
  });
  const momentSession = moment ? (sessions.find((s) => s.key === moment.key) ?? null) : null;

  // What the collapsed wings show — one winner, strict order (wing-priority.ts):
  // an agent needing you or working always beats a live activity, which beats
  // low battery, which beats weather. Nothing shows while expanded.
  const wing = expanded
    ? "empty"
    : wingContent({
        needsYou: needsYou.length,
        active: active.length,
        moment: momentSession !== null,
        activity: activity !== null,
        lowBattery: power?.low === true,
        weather: weather !== null,
      });
  // At rest — sessions present but nothing running — the rim carries a very soft
  // green-bluish breathing glow.
  const showGlow = !expanded && sessions.length > 0 && active.length === 0;
  const liveActivity = wing === "activity" ? activity : null;
  // At rest — sessions present, nothing running — the battery on the left and
  // one round bot on the right, awake: it looks around and hops now and then.
  const sleeping = showGlow && wing === "empty";
  // No sessions at all: a tiny bot dozes in the right wing so the island is
  // never just gone. It wakes (and hops) while the hello is up.
  const idleBot = !expanded && connected && sessions.length === 0 && wing === "empty";
  const wingMoment = wing === "moment" && moment && momentSession ? { ...moment, session: momentSession } : null;
  const lowBattery = wing === "low-battery" ? power : null;
  // Weather fills the collapsed island only when nothing else claims it. Note
  // this replaces the previously INVISIBLE resting state — with weather on, the
  // island is always at least a small live scene.
  const ambientWeather = wing === "weather";
  const condition = (weather?.condition ?? "clear-day") as WeatherCondition;
  // Right wing text. Keyed on its value so a change remounts and rolls in.
  const countText =
    needsYou.length > 0
      ? `${needsYou.length}!`
      : wingMoment
        ? wingMoment.kind
        : active.length > 0
        ? String(active.length)
        : liveActivity
          ? liveActivity.kind.startsWith("battery")
            ? `${liveActivity.percent}%`
            : liveActivity.kind === "focus-on"
              ? (focus?.name ?? "Focus")
              : ""
          : lowBattery
            ? `${lowBattery.percent}%`
            : ambientWeather
              ? (weather?.temperature ?? "")
              : "";
  const countLabel =
    needsYou.length > 0
      ? `${needsYou.length} sessions need attention`
      : wingMoment
        ? `${wingMoment.session.cwd.split("/").filter(Boolean).pop() ?? ""} ${
            wingMoment.kind === "done" ? "finished" : "failed"
          }`
        : liveActivity
        ? liveActivity.kind === "battery-plugged"
          ? `Charging, ${liveActivity.percent}%`
          : liveActivity.kind === "battery-unplugged"
            ? `On battery, ${liveActivity.percent}%`
            : liveActivity.kind === "battery-low"
              ? `Low battery, ${liveActivity.percent}%`
              : liveActivity.kind === "focus-on"
                ? `Focus on${focus?.name ? `: ${focus.name}` : ""}`
                : "Focus off"
        : lowBattery
          ? `Low battery, ${lowBattery.percent}%`
          : ambientWeather
            ? weather?.summary
            : sleeping
              ? `${sessions.length} sessions, all resting${power ? `, battery ${power.percent}%` : ""}`
              : idleBot
                ? `No agents running${power ? `, battery ${power.percent}%` : ""}`
              : `${active.length} active sessions`;
  // Footer total: what every visible session's agent tree is using right now.
  const totals = visible.reduce<{ cpu: number; rssMb: number } | null>((acc, s) => {
    const t = procStats[s.key];
    if (!t) return acc;
    return { cpu: (acc?.cpu ?? 0) + t.cpu, rssMb: (acc?.rssMb ?? 0) + t.rssMb };
  }, null);
  // Offline with nothing to show: the island shrinks to the notch and disappears.
  const resting = sessions.length === 0 && wing === "empty" && !idleBot;
  // While the hello is up (and you're not otherwise using the island), the
  // panel shows only the greeting.
  const greetingOnly =
    greeting !== null && !hoverExpands && !pinned && pending.length === 0 && asking.length === 0 && !assistantFocused;

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
        {!resting && (
          <>
            <i className="ear ear-l" aria-hidden />
            <i className="ear ear-r" aria-hidden />
          </>
        )}
        <div
          ref={islandBodyRef}
          className={`island ${stateCls}${expanded ? " expanded" : ""}${settled ? " settled" : ""}${
            rubber !== 0 ? " rubbering" : ""
          }${resting ? " bare" : ""}${ambientWeather ? " has-weather" : ""}${
            liveActivity ? " has-activity" : ""
          }${lowBattery ? " has-low-batt" : ""}${wingMoment ? ` has-moment moment-${wingMoment.kind}` : ""}${
            assistantOpen ? " assistant-on" : ""
          }${greetingOnly ? " greeting-only" : ""}${idleBot ? " idle-bot" : ""} spr-${shown.length}`}
          style={{ "--rubber": rubber } as CSSProperties}
          role="region"
          aria-label="Agent Island"
          onTransitionEnd={(e) => {
            if (e.target === e.currentTarget && e.propertyName === "width" && expanded) {
              setSettled(true);
            }
          }}
        >
          {pulse && (
            <div
              className="edge-spark"
              data-fx={pulse.kind}
              key={pulse.n}
              aria-hidden
              onAnimationEnd={() => setPulse(null)}
            />
          )}
          <div
            className={`notch-spacer ${stateCls}`}
            onClick={() => {
              // Swipe mode only: a click on a wing toggles, mirroring the gesture.
              if (openWith !== "swipe") return;
              window.agentIsland.haptic?.("tick");
              if (expanded && hoverExpands) setDismissed(true);
              else if (!expanded) setGestureOpen(true);
            }}
          >
            <span className="sprites">
              {wingMoment ? (
                <span className="sprite-slot wing-moment" key={`m-${wingMoment.n}`}>
                  <AgentAvatar session={wingMoment.session} now={now} size={24} interactive={false} paused={!animated} />
                </span>
              ) : sleeping || idleBot ? (
                power ? (
                  <span className="sprite-slot wing-idle-battery" key="idle-batt">
                    <Battery
                      size={16}
                      percent={power.percent}
                      charging={power.state !== "discharging"}
                      low={power.low}
                      label
                    />
                  </span>
                ) : null
              ) : liveActivity ? (
                <span className="sprite-slot" key={`la-${liveActivity.n}`}>
                  <LiveActivity kind={liveActivity.kind} percent={liveActivity.percent} />
                </span>
              ) : lowBattery ? (
                <span className="sprite-slot wing-low" key="low-batt">
                  <LiveActivity kind="battery-low" percent={lowBattery.percent} />
                </span>
              ) : ambientWeather ? (
                <span className="sprite-slot" key="weather">
                  <WeatherScene condition={condition} variant="ambient" />
                </span>
              ) : (
                shown.map(({ kind, state, tint }) => (
                  <span className="sprite-slot" key={kind}>
                    <AgentOrb state={state} tint={tint} bold paused={!animated} />
                  </span>
                ))
              )}
            </span>
            <span className={`spacer-info${lowBattery ? " wing-low" : ""}`} aria-label={countLabel}>
              {sleeping || idleBot ? (
                <IdleCrew key="crew" paused={!animated} awake={greeting !== null} />
              ) : needsYou.length === 0 && !wingMoment && active.length > 0 ? (
                <WorkCrew key="work" active={active} paused={!animated} />
              ) : (
                <span key={countText}>{countText}</span>
              )}
            </span>
          </div>

          <div className="panel-wrap" ref={panelWrapRef}>
            <div className="panel" ref={panelRef}>
              {/* `max-content` here is what makes the island content-sized: it
                  reports the panel's natural width independent of the width the
                  island currently has, so the measurement can't feed itself. */}
              <div className="panel-measure" ref={measureRef}>
              {greeting && (
                <GreetingCard
                  key={`greet-${greeting.n}`}
                  title={greeting.title}
                  line={greeting.line}
                  ai={greeting.ai}
                  paused={!animated}
                  onDismiss={dismissGreeting}
                />
              )}
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
              {sessionView === "compact" && visible.length > 0 ? (
                <ul className="bubbles">
                  {sessions.slice(0, MAX_BUBBLES).map((s, i) => (
                    <SessionBubble
                      key={s.key}
                      session={s}
                      now={now}
                      index={i}
                      paused={!expanded || !animated}
                      onJump={(sess) => window.agentIsland.jump(sess)}
                    />
                  ))}
                </ul>
              ) : (
              <ul className="rows">
                {visible.map((s, i) => (
                  <SessionRow
                    key={s.key}
                    session={s}
                    now={now}
                    index={i}
                    stats={procStats[s.key] ?? null}
                    paused={!expanded || !animated}
                    onJump={(sess) => window.agentIsland.jump(sess)}
                  />
                ))}
                {visible.length === 0 && !connected && (
                  <li className="empty">offline</li>
                )}
              </ul>
              )}
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
              <StatusFooter
                usage={usage}
                // Battery is an idle-time fact: while any agent works, the
                // footer is about the agents.
                power={active.length === 0 ? power : null}
                focus={focus}
                totals={totals}
                onClearFocus={() => window.agentIsland.clearFocus?.()}
              />
              {assistantOpen && (
                <AssistantBar
                  sessions={sessions}
                  hovering={hovering}
                  paused={!animated}
                  onFocusChange={setAssistantFocus}
                  onLiveChange={setAssistantLive}
                  voiceEnabled={aiPrefs.voice}
                  speakReplies={aiPrefs.speakReplies}
                  basic={assistantSupport === "basic"}
                  onClose={() => setAssistantOpen(false)}
                  fieldSlot={fieldSlot}
                />
              )}
              {showPrompt && !assistantOpen && needsAccess && (
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
                <span className="ctl-leading" ref={setFieldSlot}>
                  {!assistantOpen && !showPrompt && crewAvailable && sessions.length === 0 && (
                    <BotCrew
                      mood={assistantLive ? "working" : "idle"}
                      talk={sessions.length === 0 && connected && !assistantOpen}
                      paused={!expanded || !animated}
                      disabledReason={
                        crewAvailable ? null : assistantUnavailableReason(assistantSupport)
                      }
                      open={assistantOpen}
                      onClick={() => {
                        window.agentIsland.haptic?.("tick");
                        if (assistantOpen) setAssistantFocus(false);
                        setAssistantOpen((open) => !open);
                        setPromptOpen(false);
                      }}
                    />
                  )}
                  {showPrompt && !assistantOpen && (
                    <FieldBeam focused={promptFocused} paused={!animated}>
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
                          <Icon name="send" />
                        </button>
                      </form>
                    </FieldBeam>
                  )}
                </span>
                <span className="ctl-right">
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
                    <Icon name={sound.on ? "speaker" : "speaker-slash"} />
                  </button>
                  {crewAvailable && sessions.length > 0 && (
                    // With agents on screen the crew steps aside; Ask stays one click away.
                    <button
                      className={`ctl icon assistant-toggle${assistantOpen ? " on" : ""}`}
                      disabled={!crewAvailable}
                      title={
                        !crewAvailable
                          ? assistantUnavailableReason(assistantSupport)
                          : assistantOpen
                            ? "Close Apple Intelligence"
                            : "Ask Apple Intelligence"
                      }
                      aria-label={assistantOpen ? "Close Apple Intelligence" : "Ask Apple Intelligence"}
                      aria-expanded={assistantOpen}
                      onClick={(e) => {
                        e.stopPropagation();
                        window.agentIsland.haptic?.("tick");
                        if (assistantOpen) setAssistantFocus(false);
                        setAssistantOpen((open) => !open);
                        setPromptOpen(false);
                      }}
                    >
                      <Icon name="sparkles" />
                    </button>
                  )}
                  {promptTarget && (
                    <button
                      className={`ctl icon prompt-toggle${promptOpen ? " on" : ""}`}
                      title={promptOpen ? "Close the prompt" : "Send a prompt to the agent"}
                      aria-label={promptOpen ? "Close the prompt" : "Send a prompt to the agent"}
                      aria-expanded={showPrompt}
                      onClick={(e) => {
                        e.stopPropagation();
                        if (assistantOpen) {
                          setAssistantFocus(false);
                          setAssistantOpen(false);
                        }
                        togglePrompt();
                      }}
                    >
                      <Icon name="compose" />
                    </button>
                  )}
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
                    <Icon name="gear" />
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
                    <Icon name="power" />
                  </button>
                </span>
                </span>
              </div>
              </div>
            </div>
          </div>
        </div>
        <IslandGlow target={islandBodyRef} active={aiPrefs.edgeGlow && assistantOpen && expanded && animated} bright={assistantLive} />
      </div>
    </div>
  );
}
