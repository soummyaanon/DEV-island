import { BotAvatar, type BotAvatarType } from "bot-avatars";

/**
 * The island at rest: a little crew of three bots in the right wing, packed
 * tight so the island stays narrow. They look around, take turns hopping in
 * a quick wave, and every twelve seconds the last one
 * sneaks off — runs left, ducks behind the real notch, peeks out on the far
 * side, and scurries back. All the choreography is CSS on the wrappers (one
 * shared cycle, so the runner and its empty seat stay in sync); the bots
 * themselves only do their own idle looking-around.
 */

const CREW: Array<{ type: BotAvatarType; seed: number }> = [
  { type: "clover", seed: 0.12 },
  { type: "star", seed: 0.47 },
  { type: "alien", seed: 0.81 },
];

export const CREW_SIZE = 13;

export function IdleCrew({ paused, awake }: { paused: boolean; awake: boolean }) {
  const runner = CREW[CREW.length - 1];
  return (
    <>
      <span className={`idle-crew${awake ? " awake" : ""}`} aria-hidden>
        {CREW.map((b, i) => (
          <span className={`idle-bot idle-bot-${i}`} key={b.type}>
            <BotAvatar
              type={b.type}
              size={CREW_SIZE}
              state={awake ? "working" : "default"}
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
      {/* The sneaky one, on its trip behind the notch. */}
      {!awake && (
        <span className="idle-runner" aria-hidden>
          <BotAvatar
            type={runner.type}
            size={CREW_SIZE}
            state="working"
            seed={runner.seed}
            theme="dark"
            jumpEvery={0}
            interactive={false}
            paused={paused}
            aria-hidden
          />
        </span>
      )}
    </>
  );
}
