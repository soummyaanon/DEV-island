// Cursor's cube — the real mark (Simple Icons geometry): a hexagon with the
// two lower faces cut out so the top face and the edges read as a solid. Drawn
// in currentColor like the other agents; when `live`, CSS gives it a slow float.
const CUBE =
  "M11.503.131 1.891 5.678a.84.84 0 0 0-.42.726v11.188c0 .3.162.575.42.724l9.609 5.55a1 1 0 0 0 .998 0l9.61-5.55a.84.84 0 0 0 .42-.724V6.404a.84.84 0 0 0-.42-.726L12.497.131a1.01 1.01 0 0 0-.996 0M2.657 6.338h18.55c.263 0 .43.287.297.515L12.23 22.918c-.062.107-.229.064-.229-.06V12.335a.59.59 0 0 0-.295-.51l-9.11-5.257c-.109-.063-.064-.23.061-.23";

export function CursorSprite({ size = 13, live = false }: { size?: number; live?: boolean }) {
  return (
    <svg
      className={`cursor-sprite${live ? " live" : ""}`}
      width={size}
      height={size}
      viewBox="0 0 24 24"
      fill="currentColor"
      role="img"
      aria-label={live ? "Cursor working" : "Cursor"}
    >
      <path d={CUBE} />
    </svg>
  );
}
