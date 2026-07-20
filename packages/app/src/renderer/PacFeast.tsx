import { PixelSprite } from "./PixelSprite";
import { OpenAiSprite } from "./OpenAiSprite";
import { CursorSprite } from "./CursorSprite";

// Pac-Man chomping a line of agent logos as if they were dots. The crab,
// OpenAI blossom, and Cursor cube stream in from the right and vanish at his
// mouth, on a loop. Compact band only; pure-transform motion so it stays light.
const PAC_OPEN = [
  "00111100",
  "01110110",
  "11111000",
  "11110000",
  "11110000",
  "11111000",
  "01111110",
  "00111100",
];

const PAC_CLOSED = [
  "00111100",
  "01110110",
  "11111110",
  "11111111",
  "11111111",
  "11111110",
  "01111110",
  "00111100",
];

function PacFrame({ rows }: { rows: string[] }) {
  return (
    <>
      {rows.flatMap((row, y) =>
        [...row].map((pixel, x) =>
          pixel === "1" ? <rect key={`${x}-${y}`} x={x} y={y} width={1} height={1} /> : null,
        ),
      )}
    </>
  );
}

const KIND_LOGO = {
  "claude-code": PixelSprite,
  codex: OpenAiSprite,
  cursor: CursorSprite,
} as const;

const FOOD_SLOTS = 2;

/**
 * `kinds` are the agent kinds actually working right now (stable order). The
 * food line is built by cycling only those, so the dots are exactly their
 * logos: one agent → a line of that one logo; several → the logos interleaved.
 */
const CYCLE = 2.6; // seconds for one food to travel the lane

export function PacFeast({ kinds }: { kinds: (keyof typeof KIND_LOGO)[] }) {
  const slots = kinds.length
    ? Array.from({ length: FOOD_SLOTS }, (_, i) => kinds[i % kinds.length])
    : [];
  const total = slots.length || 1;

  return (
    <span className="pac-run" role="img" aria-label="agent working">
      <svg
        className="pac-man"
        width={14}
        height={14}
        viewBox="0 0 8 8"
        shapeRendering="crispEdges"
        fill="currentColor"
        aria-hidden
      >
        <g className="pac-open">
          <PacFrame rows={PAC_OPEN} />
        </g>
        <g className="pac-closed">
          <PacFrame rows={PAC_CLOSED} />
        </g>
      </svg>
      <span className="pac-food" aria-hidden>
        {slots.map((kind, i) => {
          // Evenly phase the pellets across the cycle for one steady stream.
          const style = { animationDelay: `${(-(i / total) * CYCLE).toFixed(3)}s` };
          const Logo = KIND_LOGO[kind];
          return (
            <span className="food" key={i} style={style}>
              <Logo size={9} />
            </span>
          );
        })}
      </span>
    </span>
  );
}
