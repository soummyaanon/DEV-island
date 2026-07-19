import { useEffect, useMemo, useRef, useState } from "react";
import type { AgentUsage, SessionSnapshot } from "@agent-island/shared";
import { SessionRow } from "./SessionRow";
import { ApprovalCard } from "./ApprovalCard";
import { QuestionCard } from "./QuestionCard";
import { PixelSprite } from "./PixelSprite";
import { OpenAiSprite } from "./OpenAiSprite";
import { CursorSprite } from "./CursorSprite";
import { UsageFooter } from "./UsageFooter";
import { playSound } from "./sounds";
import { DEFAULT_SOUND_PREFS, type SoundPrefs, type SoundTheme } from "./sound-prefs";

const ACTIVE_STATES = new Set(["working", "starting", "waiting-for-approval"]);
const MAX_ROWS = 5;

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

  const islandRef = useRef<HTMLDivElement>(null);
  const interactiveRef = useRef(false);
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

  // A newer release exists — surface a quiet chip in the panel footer.
  useEffect(() => window.agentIsland.onUpdate(setUpdate), []);

  // One-shot chimes pushed by main (allowing an approval, answering a question).
  useEffect(() => {
    return window.agentIsland.onChime((event) => {
      if (event === "approve") playSound("approve", soundRef.current);
    });
  }, []);

  // Alerts on state transitions: done -> success, failure -> fail, question ->
  // question chime, other needs-you -> attention. The first snapshot only
  // primes the map so relaunching the app never replays history.
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
    if (!prev || !sound.on) return;

    for (const [key, cur] of next) {
      const was = prev.get(key);
      if (!was) continue; // brand-new session: no sound until it transitions
      if (cur.state !== was.state && cur.state === "done") playSound("success", sound);
      if (cur.hasQuestion && !was.hasQuestion) playSound("question", sound);
      else if (cur.needsAction && !was.needsAction) playSound("attention", sound);
    }
  }, [sessions, sound]);

  // Notch geometry, measured by main: the black body spans the band height so
  // the shape merges with the hardware notch, and every island width derives
  // from the real notch width — so the same build hugs a 14" Pro or a 13" Air.
  useEffect(() => {
    const apply = (l: { inset: number; notchWidth: number }) => {
      document.documentElement.style.setProperty("--notch-inset", `${l.inset}px`);
      if (l.notchWidth > 0) {
        document.documentElement.style.setProperty("--notch-width", `${l.notchWidth}px`);
      }
    };
    void window.agentIsland.getLayout().then(apply);
    return window.agentIsland.onLayout(apply);
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

  // Sprites are strictly live: one per agent kind that is ACTIVELY running
  // (working / starting / waiting). Nothing running = an empty wing.
  const liveKinds = new Set(active.map((s) => s.agent));
  const shown = AGENT_SPRITES.filter((a) => liveKinds.has(a.kind));

  return (
    <div className="app">
      <div ref={islandRef} className="island-wrap">
        {(sessions.length > 0 || expanded) && (
          <>
            <i className="ear ear-l" aria-hidden />
            <i className="ear ear-r" aria-hidden />
          </>
        )}
        <div
          className={`island ${stateCls}${expanded ? " expanded" : ""}${
            sessions.length === 0 ? " bare" : ""
          } spr-${shown.length}`}
        >
          <div className={`notch-spacer ${stateCls}`}>
            <span className="sprites">
              {shown.map(({ kind, Sprite }) => (
                <Sprite key={kind} live />
              ))}
            </span>
            <span
              className="spacer-info"
              aria-label={
                needsYou.length > 0
                  ? `${needsYou.length} sessions need attention`
                  : `${active.length} active sessions`
              }
            >
              {needsYou.length > 0 ? `${needsYou.length}!` : active.length > 0 ? active.length : ""}
            </span>
          </div>

          <div className="panel-wrap">
            <div className="panel">
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
              <UsageFooter usage={usage} />
              {promptTarget && (
                <form
                  className="prompt-bar"
                  onSubmit={(e) => {
                    e.preventDefault();
                    submitPrompt();
                  }}
                >
                  <input
                    className="prompt-input"
                    type="text"
                    value={promptText}
                    placeholder="Ask the agent…"
                    aria-label="Send a prompt to the agent"
                    spellCheck={false}
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
              <div className="panel-controls">
                <button
                  className={`ctl icon${sound.on ? "" : " off"}`}
                  title={sound.on ? "Sound on" : "Sound off"}
                  aria-label={sound.on ? "Sound on" : "Sound off"}
                  onClick={(e) => {
                    e.stopPropagation();
                    window.agentIsland.setSounds(!sound.on);
                  }}
                >
                  ♪
                </button>
                {update ? (
                  <button
                    className="ctl update"
                    title={`Download Agent Island ${update.version}`}
                    onClick={(e) => {
                      e.stopPropagation();
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
  );
}
