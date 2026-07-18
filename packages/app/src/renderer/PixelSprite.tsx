// Classic two-frame invader/crab. When `live`, CSS flips frames like the
// original arcade sprite (arms up / arms down).
const FRAME_A = [
  "01000000010",
  "00100000100",
  "00111111100",
  "01101110110",
  "11111111111",
  "10111111101",
  "10100000101",
  "00011011000",
];

const FRAME_B = [
  "01000000010",
  "10100000101",
  "10111111101",
  "11101110111",
  "11111111111",
  "01111111110",
  "00100000100",
  "01000000010",
];

function Frame({ rows }: { rows: string[] }) {
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

export function PixelSprite({ size = 13, live = false }: { size?: number; live?: boolean }) {
  return (
    <svg
      className={`pixel-sprite${live ? " live" : ""}`}
      width={size}
      height={Math.round((size * 8) / 11)}
      viewBox="0 0 11 8"
      shapeRendering="crispEdges"
      fill="currentColor"
      aria-hidden
    >
      <g className="f1">
        <Frame rows={FRAME_A} />
      </g>
      <g className="f2">
        <Frame rows={FRAME_B} />
      </g>
    </svg>
  );
}
