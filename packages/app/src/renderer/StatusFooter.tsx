import type { AgentUsage } from "@agent-island/shared";
import type { CSSProperties, ReactNode } from "react";
import { Battery, Icon } from "./Icons";
import { ClaudeSprite } from "./ClaudeSprite";
import { OpenAiSprite } from "./OpenAiSprite";
import { CursorSprite } from "./CursorSprite";

/**
 * One footer row: each agent's 5-hour and weekly limits as small rings, then the ambient facts — battery,
 * Focus, what the agents are costing. Each item is optional; the row hides
 * when it would be empty.
 */

const WINDOW_ORDER = ["5h", "weekly", "daily", "monthly", "spend"];
const windowRank = (label: string) => {
  const i = WINDOW_ORDER.indexOf(label);
  return i === -1 ? WINDOW_ORDER.length : i;
};
const SHORT_LABEL: Record<string, string> = { "5h": "5h", weekly: "wk", daily: "day", monthly: "mo", spend: "$" };
const WINDOW_NAME: Record<string, string> = {
  "5h": "5-hour",
  weekly: "weekly",
  daily: "daily",
  monthly: "monthly",
  spend: "spend",
};

/** "2h 10m" / "3d 4h" / "12m" until a Unix-seconds reset. */
export function formatResetIn(resetsAtSec: number, now: number): string {
  const mins = Math.max(0, Math.round((resetsAtSec * 1000 - now) / 60000));
  const d = Math.floor(mins / 1440);
  const h = Math.floor((mins % 1440) / 60);
  const m = mins % 60;
  if (d > 0) return `${d}d ${h}h`;
  if (h > 0) return `${h}h ${m}m`;
  return `${m}m`;
}

/** "just now" / "40s ago" / "3m ago" — how fresh a reading is. */
export function formatAge(iso: string, now: number): string {
  const secs = Math.max(0, Math.round((now - Date.parse(iso)) / 1000));
  if (secs < 5) return "just now";
  if (secs < 60) return `${secs}s ago`;
  return `${Math.round(secs / 60)}m ago`;
}

/**
 * A limit as a small ring: the arc is what's USED, warming as it fills. It
 * draws itself in when it appears and glides to each new reading; past 90%
 * it pulses softly so a nearly spent window is noticed without shouting.
 * (All CSS; reduced motion shows the final arc at once.)
 */
function QuotaRing({ used, size = 13 }: { used: number; size?: number }) {
  const r = 6.2;
  const c = 2 * Math.PI * r;
  const tone = used >= 90 ? "var(--failed)" : used >= 70 ? "var(--waiting)" : "var(--done)";
  return (
    <svg
      width={size}
      height={size}
      viewBox="0 0 16 16"
      className={`ring quota-ring${used >= 90 ? " hot" : ""}`}
      style={{ "--ring-c": c.toFixed(2), "--ring-tone": tone } as CSSProperties}
      aria-hidden
    >
      <circle cx="8" cy="8" r={r} fill="none" stroke="currentColor" strokeOpacity="0.16" strokeWidth="2" />
      <circle
        className="quota-arc"
        cx="8"
        cy="8"
        r={r}
        fill="none"
        stroke={tone}
        strokeWidth="2"
        strokeLinecap="round"
        strokeDasharray={c.toFixed(2)}
        strokeDashoffset={(c * (1 - used / 100)).toFixed(2)}
        transform="rotate(-90 8 8)"
      />
    </svg>
  );
}

/** Each agent's own mark beside its limits, instead of a word. */
const AGENT_MARK: Record<string, (size: number) => ReactNode> = {
  "claude-code": (size) => <ClaudeSprite size={size} />,
  codex: (size) => <OpenAiSprite size={size} />,
  cursor: (size) => <CursorSprite size={size} />,
};

const AGENT_LABEL: Record<string, string> = {
  "claude-code": "claude",
  codex: "codex",
  cursor: "cursor",
};

export interface FooterPower {
  percent: number;
  state: "charging" | "discharging" | "charged" | "ac";
  minutesRemaining: number | null;
  low: boolean;
}

export interface FooterFocus {
  active: boolean;
  name: string | null;
}

export interface FooterTotals {
  cpu: number;
  rssMb: number;
}

export function formatMemory(rssMb: number): string {
  return rssMb >= 1024 ? `${(rssMb / 1024).toFixed(1)} GB` : `${rssMb} MB`;
}

export function formatRemaining(minutes: number | null): string {
  if (minutes === null || minutes <= 0) return "";
  const h = Math.floor(minutes / 60);
  const m = minutes % 60;
  return h > 0 ? `${h}:${String(m).padStart(2, "0")}` : `${m}m`;
}

export function StatusFooter({
  usage,
  power,
  focus,
  totals,
  onClearFocus,
}: {
  usage: AgentUsage[];
  power: FooterPower | null;
  focus: FooterFocus | null;
  totals: FooterTotals | null;
  onClearFocus: () => void;
}) {
  const quotas = usage.flatMap((entry) => {
    // 5-hour first, then weekly; anything else (daily, spend) after.
    const windows = [...entry.windows].sort((a, b) => windowRank(a.label) - windowRank(b.label)).slice(0, 2);
    if (windows.length === 0 && !entry.credits) return [];
    return [
      {
        kind: entry.agent,
        agent: AGENT_LABEL[entry.agent] ?? entry.agent,
        windows,
        credits: entry.credits,
        updatedAt: entry.updated_at,
      },
    ];
  });

  const showFocus = focus?.active === true;
  const showTotals = totals !== null && totals.cpu + totals.rssMb > 0;
  if (quotas.length === 0 && !power && !showFocus && !showTotals) return null;

  // Spoken/tooltip detail; the ring itself carries the number visually.
  const powerDetail = power
    ? power.state === "discharging"
      ? `${power.percent}% battery${power.minutesRemaining ? `, ${formatRemaining(power.minutesRemaining)} left` : ""}`
      : power.state === "charging"
        ? `${power.percent}%, charging${power.minutesRemaining ? `, ${formatRemaining(power.minutesRemaining)} to full` : ""}`
        : power.state === "charged"
          ? "Fully charged"
          : `${power.percent}%, on power`
    : "";

  return (
    <div className="usage-compact">
      {quotas.map((quota) => (
        <span className="usage-item quota" key={quota.agent}>
          {AGENT_MARK[quota.kind] ? (
            <span className="quota-mark" title={quota.agent}>
              {AGENT_MARK[quota.kind](11)}
            </span>
          ) : (
            <b>{quota.agent}</b>
          )}
          {quota.windows.map((w) => {
            const used = Math.max(0, Math.min(100, Math.round(w.used_percent)));
            const detail = `${quota.agent} ${WINDOW_NAME[w.label] ?? w.label} limit: ${used}% used${
              w.resets_at ? `, resets in ${formatResetIn(w.resets_at, Date.now())}` : ""
            }${quota.updatedAt ? ` · as of ${formatAge(quota.updatedAt, Date.now())}` : ""}`;
            return (
              <span className="quota-window" key={w.label} title={detail} aria-label={detail}>
                <QuotaRing used={used} />
                <span className="quota-label">{SHORT_LABEL[w.label] ?? w.label}</span>
                <span className="quota-value">{used}%</span>
              </span>
            );
          })}
          {quota.credits && <span>{quota.credits} credits</span>}
        </span>
      ))}
      {power && (
        <span
          className={`usage-item power${power.low ? " low" : ""}${power.state !== "discharging" ? " on-power" : ""}`}
          title={powerDetail}
          aria-label={powerDetail}
        >
          <Battery percent={power.percent} charging={power.state !== "discharging"} low={power.low} />
          <b>{power.percent}%</b>
        </span>
      )}
      {showFocus && (
        <button
          type="button"
          className="usage-item focus-chip"
          title="Focus is on (from your Shortcuts automation). Click if it stayed on by mistake."
          onClick={(e) => {
            e.stopPropagation();
            onClearFocus();
          }}
        >
          <Icon name="moon" size={12} />
          <b>{focus?.name ?? "Focus"}</b>
        </button>
      )}
      {showTotals && totals && (
        <span className="usage-item meter-total" title="What your agents are using right now">
          <Icon name="cpu" size={12} />
          <b>{totals.cpu}%</b>
          <span>{formatMemory(totals.rssMb)}</span>
        </span>
      )}
    </div>
  );
}
