import { useEffect, useId, useState, type RefObject } from "react";

/**
 * The assistant's glow — border-beam's Pulse Inner look in Mono, but on
 * the island's REAL outline. border-beam can only trace a rectangle, which boxed
 * the island in. The island isn't a box: it grows out of the bezel through two
 * concave "ears", runs down its sides and rounds off at the bottom. This glows
 * INWARD from exactly that shape (ears included) — a soft wash that fades
 * about 28px into the island, like pulse-inner, not a line on the edge — and
 * never along the top edge, which is the bezel itself.
 */

/** Concave ear radius and bottom corner radius (island.css .ear / .expanded). */
export const EAR = 10;
export const CORNER = 16;

/** The edge, left ear → sides → bottom → right ear, in a box EAR wider each side. */
export function islandOutline(width: number, height: number, ear = EAR, corner = CORNER): string {
  const r = Math.min(corner, width / 2, height / 2);
  const x0 = ear;
  const x1 = ear + width;
  return [
    `M 0 0`,
    `A ${ear} ${ear} 0 0 1 ${x0} ${ear}`,
    `L ${x0} ${height - r}`,
    `A ${r} ${r} 0 0 0 ${x0 + r} ${height}`,
    `L ${x1 - r} ${height}`,
    `A ${r} ${r} 0 0 0 ${x1} ${height - r}`,
    `L ${x1} ${ear}`,
    `A ${ear} ${ear} 0 0 1 ${x1 + ear} 0`,
  ].join(" ");
}

/** The same edge closed along the bezel: the island's whole silhouette. */
export function islandSilhouette(width: number, height: number): string {
  return `${islandOutline(width, height)} Z`;
}

/** The island body's live size while `active`, following every resize. */
export function useIslandSize(
  target: RefObject<HTMLElement | null>,
  active: boolean,
): { w: number; h: number } | null {
  const [size, setSize] = useState<{ w: number; h: number } | null>(null);

  useEffect(() => {
    const el = target.current;
    if (!el || !active) return;
    let frame = 0;
    const measure = () => {
      frame = 0;
      setSize({ w: el.offsetWidth, h: el.offsetHeight });
    };
    const observer = new ResizeObserver(() => {
      if (frame === 0) frame = requestAnimationFrame(measure);
    });
    observer.observe(el);
    measure();
    return () => {
      observer.disconnect();
      if (frame !== 0) cancelAnimationFrame(frame);
    };
  }, [target, active]);

  return size;
}

export function IslandGlow({
  target,
  active,
  bright,
}: {
  target: RefObject<HTMLElement | null>;
  active: boolean;
  /** A little stronger while an answer is being worked on. */
  bright: boolean;
}) {
  const size = useIslandSize(target, active);
  const uid = useId().replace(/:/g, "");

  if (!active || !size || size.w <= 0) return null;
  const edge = islandOutline(size.w, size.h);
  const boxW = size.w + EAR * 2;
  return (
    <svg
      className={`island-glow${bright ? " bright" : ""}`}
      width={boxW}
      height={size.h}
      viewBox={`0 0 ${boxW} ${size.h}`}
      aria-hidden
    >
      <defs>
        <linearGradient id={`beam-${uid}`} x1="0" y1="0" x2="1" y2="0">
          {/* border-beam's Mono palette: silver greys, no hue at all. */}
          <stop offset="0%" stopColor="rgb(150, 150, 150)" />
          <stop offset="30%" stopColor="rgb(215, 215, 215)" />
          <stop offset="55%" stopColor="rgb(175, 175, 175)" />
          <stop offset="80%" stopColor="rgb(230, 230, 230)" />
          <stop offset="100%" stopColor="rgb(160, 160, 160)" />
        </linearGradient>
        {/* Inner: everything is clipped to the silhouette, so the glow only
            ever falls inside the island, like pulse-inner. */}
        <clipPath id={`inside-${uid}`}>
          <path d={islandSilhouette(size.w, size.h)} />
        </clipPath>
      </defs>
      <g clipPath={`url(#inside-${uid})`}>
        <path className="glow-bloom" d={edge} fill="none" stroke={`url(#beam-${uid})`} strokeWidth={56} />
        <path className="glow-line" d={edge} fill="none" stroke={`url(#beam-${uid})`} strokeWidth={1.5} />
      </g>
    </svg>
  );
}
