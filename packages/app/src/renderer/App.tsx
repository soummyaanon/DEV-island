import { useEffect, useMemo, useRef, useState } from "react";
import type { SessionSnapshot } from "@agent-island/shared";
import { SessionRow, StatusDot } from "./SessionRow";

const ACTIVE_STATES = new Set(["working", "starting", "waiting-for-approval"]);
const MAX_ROWS = 6;

export function App() {
  const [sessions, setSessions] = useState<SessionSnapshot[]>([]);
  const [connected, setConnected] = useState(false);
  const [hovering, setHovering] = useState(false);
  const [pinned, setPinned] = useState(false);
  const [now, setNow] = useState(() => Date.now());

  const islandRef = useRef<HTMLDivElement>(null);
  const interactiveRef = useRef(false);

  const expanded = hovering || pinned;

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
    return () => {
      offSessions();
      offToggle();
    };
  }, []);

  // Tick elapsed timers once a second.
  useEffect(() => {
    const id = window.setInterval(() => setNow(Date.now()), 1000);
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
  const attention = useMemo(() => sessions.filter((s) => s.requires_action), [sessions]);
  const visible = useMemo(() => sessions.slice(0, MAX_ROWS), [sessions]);

  return (
    <div className="app">
      <div
        ref={islandRef}
        className={`island${expanded ? " expanded" : ""}${attention.length ? " attention" : ""}`}
        onClick={() => setPinned((v) => !v)}
      >
        <div className="pill">
          <span className="brand" aria-hidden />
          <div className="pill-dots">
            {active.length === 0 ? (
              <span className={`dot ${connected ? "state-idle" : "offline"}`} />
            ) : (
              active.slice(0, 4).map((s) => <StatusDot key={s.key} state={s.state} />)
            )}
          </div>
          <span className="pill-count">
            {attention.length > 0 ? "⚠" : active.length > 0 ? active.length : ""}
          </span>
        </div>

        <div className="panel-wrap">
          <div className="panel">
            <header className="panel-head">
              <span className="wordmark">Agent Island</span>
              <span className="badge">
                {connected ? `${active.length} active` : "offline"}
              </span>
            </header>
            <ul className="rows">
              {visible.map((s, i) => (
                <SessionRow
                  key={s.key}
                  session={s}
                  now={now}
                  index={i}
                  onJump={(sess) => window.agentIsland.jump(sess)}
                />
              ))}
              {visible.length === 0 && (
                <li className="empty">{connected ? "no sessions yet" : "waiting for daemon…"}</li>
              )}
            </ul>
          </div>
        </div>
      </div>
    </div>
  );
}
