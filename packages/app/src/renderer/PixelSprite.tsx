// A classic 11x8 pixel-art "invader" rendered as crisp SVG rects. Colored via
// currentColor (so state classes tint it) and glows via CSS filter animation.
const INVADER = [
  "00100000100",
  "00010001000",
  "00111111100",
  "01101110110",
  "11111111111",
  "10111111101",
  "10100000101",
  "00011011000",
];

export function PixelSprite({ size = 16 }: { size?: number }) {
  const rects: React.ReactNode[] = [];
  for (let y = 0; y < INVADER.length; y++) {
    for (let x = 0; x < INVADER[y].length; x++) {
      if (INVADER[y][x] === "1") {
        rects.push(<rect key={`${x}-${y}`} x={x} y={y} width={1} height={1} />);
      }
    }
  }
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
      {rects}
    </svg>
  );
}
