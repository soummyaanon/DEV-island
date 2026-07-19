// Cursor's isometric cube, reduced to strokes that stay crisp at 13px. Drawn
// in currentColor like the other sprites; when `live`, CSS gives it a gentle
// floating bob (spin belongs to the blossom, walking to the crab).
export function CursorSprite({ size = 13, live = false }: { size?: number; live?: boolean }) {
  return (
    <svg
      className={`cursor-sprite${live ? " live" : ""}`}
      width={size}
      height={size}
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth={2.4}
      strokeLinejoin="round"
      strokeLinecap="round"
      role="img"
      aria-label={live ? "Cursor working" : "Cursor"}
    >
      <path d="M12 2.5 L20.2 7.25 V16.75 L12 21.5 L3.8 16.75 V7.25 Z" />
      <path d="M12 21.5 V12 L20.2 7.25 M12 12 L3.8 7.25" />
    </svg>
  );
}
