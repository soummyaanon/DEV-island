import { useEffect, useState } from "react";
import { BotAvatar, type BotAvatarType } from "bot-avatars";
import { useReducedMotion } from "./a11y";

/**
 * The island at rest: a little crew of three bots in the right wing, packed
 * tight so the island stays narrow, playing hide and seek. The one on the
 * right is "it": it shuts its eyes and counts while the other two hide — one
 * sneaks left behind the real notch, one ducks below the band — then it opens
 * its eyes, and each hider peeks out and comes home in turn. Every move is a
 * slow slide (CSS transitions on the wrappers), never a hop, so the island
 * itself stays calm. While the hello is up they dance on the spot instead.
 */

const CREW: Array<{ type: BotAvatarType; seed: number }> = [
  { type: "clover", seed: 0.12 },
  { type: "star", seed: 0.47 },
  { type: "alien", seed: 0.81 },
];

export const CREW_SIZE = 13;

/** One round of the game, in seconds. */
export const ROUND_S = 16;

/** Where a hider is: in its seat, peeking out, or out of sight. */
export type HiderPose = "seat" | "peek" | "hidden";

export interface GamePose {
  /** The seeker has its eyes shut and is counting. */
  counting: boolean;
  /** The bot that hides behind the notch (left), then the one that ducks. */
  notch: HiderPose;
  duck: HiderPose;
}

/** The game's pose `t` seconds into the round (wraps). */
export function gamePose(t: number): GamePose {
  const s = ((t % ROUND_S) + ROUND_S) % ROUND_S;
  const counting = s >= 3 && s < 9;
  const duck: HiderPose = s < 3.4 ? "seat" : s < 10.5 ? "hidden" : s < 12 ? "peek" : "seat";
  const notch: HiderPose = s < 3.8 ? "seat" : s < 13 ? "hidden" : s < 14.5 ? "peek" : "seat";
  return { counting, notch, duck };
}

export function IdleCrew({ paused, awake }: { paused: boolean; awake: boolean }) {
  const reduced = useReducedMotion();
  const playing = !awake && !paused && !reduced;
  const [t, setT] = useState(0);
  useEffect(() => {
    if (!playing) return;
    const start = Date.now();
    setT(0);
    const id = window.setInterval(() => setT((Date.now() - start) / 1000), 250);
    return () => window.clearInterval(id);
  }, [playing]);
  const pose: GamePose = playing ? gamePose(t) : { counting: false, notch: "seat", duck: "seat" };
  const poses: string[] = [`hide-notch-${pose.notch}`, `hide-duck-${pose.duck}`, pose.counting ? "counting" : ""];
  return (
    <span className={`idle-crew${awake ? " awake" : ""}`} aria-hidden>
      {CREW.map((b, i) => (
        <span className={`idle-bot idle-bot-${i} ${poses[i]}`} key={b.type}>
          <BotAvatar
            type={b.type}
            size={CREW_SIZE}
            state={pose.counting && i === 2 ? "sleeping" : "default"}
            seed={b.seed}
            theme="dark"
            turn={1.6}
            jumpEvery={0}
            interactive={false}
            paused={paused}
            aria-hidden
          />
        </span>
      ))}
    </span>
  );
}
