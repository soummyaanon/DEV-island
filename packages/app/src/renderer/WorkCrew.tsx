import { BotAvatar } from "bot-avatars";
import type { SessionSnapshot } from "@agent-island/shared";
import { AGENT_LOOK, sessionSeed } from "./agent-avatar";

/**
 * The right wing while agents work: one bot per working session instead of a
 * bare count, each in its agent's own shape and colour (Claude the orange
 * mech, Codex the green droid, Cursor the blue hexagon). Past three the rest
 * fold into a small "+n". The busy motion stays inside each bot's own canvas,
 * a small bob rather than a full hop, so the island itself never moves.
 */

export const MAX_WORK_BOTS = 3;
export const WORK_BOT_SIZE = 14;

/** The bots to draw and how many fold into "+n". */
export function workCrew<T>(active: T[]): { shown: T[]; more: number } {
  return { shown: active.slice(0, MAX_WORK_BOTS), more: Math.max(0, active.length - MAX_WORK_BOTS) };
}

export function WorkCrew({ active, paused }: { active: SessionSnapshot[]; paused: boolean }) {
  const { shown, more } = workCrew(active);
  return (
    <span className={`work-crew${more > 0 ? " more" : ""}`} aria-hidden>
      {shown.map((s) => {
        const look = AGENT_LOOK[s.agent] ?? AGENT_LOOK["claude-code"];
        return (
          <span className="work-bot" key={s.key}>
            <BotAvatar
              type={look.type}
              color={look.color}
              size={WORK_BOT_SIZE}
              state="working"
              seed={sessionSeed(s.key ?? s.session_id ?? "")}
              theme="dark"
              jumpHeight={9}
              jumpSquash={0.6}
              jumpSpin={0}
              interactive={false}
              paused={paused}
              aria-hidden
            />
          </span>
        );
      })}
      {more > 0 && <span className="work-more">+{more}</span>}
    </span>
  );
}
