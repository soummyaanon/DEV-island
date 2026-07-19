import { useEffect, useMemo, useRef, useState } from "react";
import type { AgentUsage, SessionSnapshot } from "@agent-island/shared";
import { SessionRow } from "./SessionRow";
import { ApprovalCard } from "./ApprovalCard";
import { QuestionCard } from "./QuestionCard";
import { PixelSprite } from "./PixelSprite";
import { OpenAiSprite } from "./OpenAiSprite";
import { UsageFooter } from "./UsageFooter";
import { playAttention, playFail, playSuccess } from "./sounds";

const ACTIVE_STATES = new Set(["working", "starting", "waiting-for-approval"]);
const MAX_ROWS = 5;

export function App() {
  const [sessions, setSessions] = useState<SessionSnapshot[]>([]);
  const [usage, setUsage] = useState<AgentUsage[]>([]);
  const [connected, setConnected] = useState(false);
  const [hovering, setHovering] = useState(false);
  const [pinned, setPinned] = useState(false);
  const [now, setNow] = useState(() => Date.now());

  const islandRef = useRef<HTMLDivElement>(null);
  const interactiveRef = useRef(false);
  const [soundsOn, setSoundsOn] = useState(true);
  const prevStates = useRef<Map<string, { state: string; needsAction: boolean }> | null>(null);

  const pending = useMemo(() => sessions.filter((s) => s.pending_approval), [sessions]);
  const asking = useMemo(() => sessions.filter((s) => s.pending_question), [sessions]);
  const needsYou = useMemo(
    () => sessions.filter((s) => s.state === "waiting-for-approval"),
    [sessions],
  );
  // Anything waiting on the human forces the panel open automatically.
  const expanded =
    hovering || pinned || pending.length > 0 || asking.length > 0 || needsYou.length > 0;

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

  // Sound toggle lives in the tray menu.
  useEffect(() => {
    void window.agentIsland.getSounds().then(setSoundsOn);
    return window.agentIsland.onSounds(setSoundsOn);
  }, []);

  // 8-bit alerts on state transitions: done -> success arpeggio, failure ->
  // buzz, needs-you -> double ping. The first snapshot only primes the map so
  // relaunching the app never replays history.
  useEffect(() => {
    const next = new Map(
      sessions.map((s) => [
        s.key,
        { state: s.state, needsAction: s.requires_action || s.pending_approval !== null },
      ]),
    );
    const prev = prevStates.current;
    prevStates.current = next;
    if (!prev || !soundsOn) return;

    for (const [key, cur] of next) {
      const was = prev.get(key);
      if (!was) continue; // brand-new session: no sound until it transitions
      if (cur.state !== was.state) {
        if (cur.state === "done") playSuccess();
        else if (cur.state === "failed") playFail();
      }
      if (cur.needsAction && !was.needsAction) playAttention();
    }
  }, [sessions, soundsOn]);

  // Notch band height, measured by main: the black body spans it so the shape
  // merges with the hardware notch; content renders below it.
  useEffect(() => {
    const apply = (l: { inset: number }) =>
      document.documentElement.style.setProperty("--notch-inset", `${l.inset}px`);
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

  // One sprite per agent kind: the crab stays the default face; the OpenAI mark
  // appears for Codex sessions; both wave side by side when both are around.
  const hasCodex = sessions.some((s) => s.agent === "codex");
  const showCrab = sessions.some((s) => s.agent === "claude-code") || !hasCodex;
  const claudeLive = active.some((s) => s.agent === "claude-code");
  const codexLive = active.some((s) => s.agent === "codex");
  const dual = showCrab && hasCodex;

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
          }${dual ? " dual" : ""}`}
        >
          <div className={`notch-spacer ${stateCls}`}>
            <span className="sprites">
              {showCrab && <PixelSprite live={claudeLive} />}
              {hasCodex && <OpenAiSprite live={codexLive} />}
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
                  key={`q-${s.key}`}
                  session={s}
                  onJump={(sess) => window.agentIsland.jump(sess)}
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
            </div>
          </div>
        </div>
      </div>
    </div>
  );
}
