// The OpenAI blossom mark — the official petal geometry, one petal repeated at
// 60° steps around the center. Drawn in currentColor so it takes the same
// state tint as the crab; when `live`, CSS spins it slowly.
const PETAL =
  "M1107.3 299.1c-197.999 0-373.9 127.3-435.2 315.3L650 743.5v427.9c0 21.4 11 " +
  "40.4 29.4 51.4l344.5 198.515V833.3h.1v-27.9L1372.7 604c33.715-19.52 " +
  "70.44-32.857 108.47-39.828L1447.6 450.3C1361 353.5 1237.1 298.5 1107.3 " +
  "299.1zm0 117.5-.6.6c79.699 0 156.3 27.5 217.6 78.4-2.5 1.2-7.4 4.3-11 " +
  "6.1L952.8 709.3c-18.4 10.4-29.4 30-29.4 51.4V1248l-155.1-89.4V755.8c-.1" +
  "-187.099 151.601-338.9 339-339.2z";

const ANGLES = [0, 60, 120, 180, 240, 300];

export function OpenAiSprite({ size = 13, live = false }: { size?: number; live?: boolean }) {
  return (
    <svg
      className={`openai-sprite${live ? " live" : ""}`}
      width={size}
      height={size}
      viewBox="0 0 2406 2406"
      fill="currentColor"
      role="img"
      aria-label={live ? "Codex working" : "Codex"}
    >
      {ANGLES.map((angle) => (
        <path
          key={angle}
          d={PETAL}
          transform={angle ? `rotate(${angle} 1203 1203)` : undefined}
        />
      ))}
    </svg>
  );
}
