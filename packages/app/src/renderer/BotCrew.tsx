import { useEffect, useState } from "react";
import { BotAvatar, type BotAvatarState, type BotAvatarType } from "bot-avatars";

/**
 * The assistant, as three small bots in the footer's left corner. They are
 * the door to Apple Intelligence: click them and the Ask bar opens. With
 * nothing running they say so and offer to help, one line at a time; while
 * an answer streams they hop along with it.
 *
 * Deliberately NOT the agents' own shapes (cat / flower / cube) — these are
 * the island's helpers, not your sessions.
 */

const CREW: Array<{ type: BotAvatarType; seed: number }> = [
  { type: "clover", seed: 0.12 },
  { type: "star", seed: 0.47 },
  { type: "alien", seed: 0.81 },
];

/** What they say when the island is empty, one line every few seconds. */
export const CREW_LINES = [
  "Nothing running. Ask us anything",
  "Need a hand with something?",
  "What should we build next?",
  "Ask a question, draft an email…",
];

const LINE_MS = 4500;

export function BotCrew({
  mood,
  talk,
  paused,
  disabledReason,
  open,
  onClick,
}: {
  /** working = an answer is streaming; idle = resting. */
  mood: "idle" | "working";
  /** Show the rotating invitation beside them (empty island). */
  talk: boolean;
  paused: boolean;
  /** Set when Apple Intelligence can't answer — shown instead of opening. */
  disabledReason: string | null;
  open: boolean;
  onClick: () => void;
}) {
  const [line, setLine] = useState(0);
  useEffect(() => {
    if (!talk || paused) return;
    const id = window.setInterval(() => setLine((i) => (i + 1) % CREW_LINES.length), LINE_MS);
    return () => window.clearInterval(id);
  }, [talk, paused]);

  const state: BotAvatarState = mood === "working" ? "working" : "default";
  const label = disabledReason ?? (open ? "Close Apple Intelligence" : "Ask Apple Intelligence");
  return (
    <button
      type="button"
      className={`bot-crew${open ? " on" : ""}${talk ? " talking" : ""}`}
      title={label}
      aria-label={label}
      aria-expanded={open}
      aria-disabled={disabledReason !== null}
      onClick={(e) => {
        e.stopPropagation();
        if (disabledReason) return;
        onClick();
      }}
    >
      <span className="bot-crew-bots" aria-hidden>
        {CREW.map((b) => (
          <BotAvatar
            key={b.type}
            type={b.type}
            size={22}
            state={state}
            seed={b.seed}
            theme="dark"
            turn={1.4}
            paused={paused}
            aria-hidden
          />
        ))}
      </span>
      {talk && (
        <span className="bot-crew-line" key={line} aria-hidden>
          {disabledReason ?? CREW_LINES[line]}
        </span>
      )}
    </button>
  );
}
