const CRAB = [
  "01000000010",
  "00100000100",
  "00111111100",
  "01101110110",
  "11111111111",
  "10111111101",
  "10100000101",
  "00011011000",
];

export function PixelSprite({ size = 13 }: { size?: number }) {
  return (
    <svg
      className="pixel-sprite"
      width={size}
      height={Math.round((size * 8) / 11)}
      viewBox="0 0 11 8"
      shapeRendering="crispEdges"
      fill="currentColor"
      aria-hidden
    >
      {CRAB.flatMap((row, y) =>
        [...row].map((pixel, x) =>
          pixel === "1" ? <rect key={`${x}-${y}`} x={x} y={y} width={1} height={1} /> : null,
        ),
      )}
    </svg>
  );
}
