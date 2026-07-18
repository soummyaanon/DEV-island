import { useEffect, useMemo, useRef, useState } from "react";
import type { AgentUsage, SessionSnapshot } from "@agent-island/shared";
import { SessionRow } from "./SessionRow";
import { ApprovalCard } from "./ApprovalCard";
import { UsageFooter } from "./UsageFooter";
import { PixelSprite } from "./PixelSprite";

const ACTIVE_STATES = new Set(["working", "starting", "waiting-for-approval"]);
const MAX_ROWS = 6;

export function App() {
  const [sessions, setSessions] = useState<SessionSnapshot[]>([]);
  const [usage, setUsage] = useState<AgentUsage[]>([]);
  const [connected, setConnected] = useState(false);
  const [hovering, setHovering] = useState(false);
  const [pinned, setPinned] = useState(false);
  const [now, setNow] = useState(() => Date.now());

  const islandRef = useRef<HTMLDivElement>(null);
  const interactiveRef = useRef(false);

  const pending = useMemo(() => sessions.filter((s) => s.pending_approval), [sessions]);
  // A pending approval demands attention: force the panel open and interactive.
  const expanded = hovering || pinned || pending.length > 0;

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

  // Tick elapsed timers once a second.
  useEffect(() => {
    const id = window.setInterval(() => setNow(Date.now()), 1000);
    return () => window.clearInterval(id);
  }, []);

  // Hug geometry: main measures where the window really sits and tells us how
  // many px separate the window top from the notch's bottom line.
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
  const attention = useMemo(() => sessions.filter((s) => s.requires_action), [sessions]);
  const visible = useMemo(() => sessions.slice(0, MAX_ROWS), [sessions]);
  const dominant = pending[0] ?? active[0] ?? sessions[0] ?? null;

  return (
    <div className="app">
      <div
        ref={islandRef}
        className={`island${expanded ? " expanded" : ""}${
          attention.length || pending.length ? " attention" : ""
        }`}
        onClick={() => setPinned((v) => !v)}
      >
        {/* Collapsed: content lives in the wings BESIDE the notch (iPhone island). */}
        <div className={`pill ${dominant ? `state-${dominant.state}` : connected ? "idle" : "offline"}`}>
          <span className="sprite">
            <PixelSprite size={16} />
          </span>
          <span className="pill-right">
            {attention.length > 0 && <span className="pill-alert">{attention.length}</span>}
            <span className={`eq${active.length > 0 ? " live" : ""}`}>
              <i />
              <i />
              <i />
              <i />
            </span>
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
            <UsageFooter usage={usage} now={now} />
          </div>
        </div>
      </div>
    </div>
  );
}
