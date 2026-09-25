import type { ReactNode } from "react";
import { BorderBeam } from "border-beam";

/**
 * The island's text fields wear a soft sunset pulse instead of a focus ring:
 * it fades in when you start typing and out when you leave. The field
 * itself stays a quiet dark pill; the beam is the only thing that says "live".
 *
 * While a submitted question is being answered (`loading`), the pulse turns
 * into a `line` glow travelling the bottom edge until the words arrive — the
 * Libraries.dev rule for an input that loads after submit. (Pulse-inner, not
 * pulse-outside, for typing: the island clips anything blooming outward.)
 */
export function FieldBeam({
  focused,
  loading = false,
  paused = false,
  children,
}: {
  focused: boolean;
  /** Submitted and waiting for the first words back. */
  loading?: boolean;
  paused?: boolean;
  children: ReactNode;
}) {
  return (
    <BorderBeam
      className="field-beam"
      size={loading ? "line" : "pulse-inner"}
      colorVariant="sunset"
      // Pure palette: the library's hue drift wanders off-colour on black.
      staticColors
      theme="dark"
      strength={loading ? 0.6 : 0.35}
      borderRadius={14}
      active={(focused || loading) && !paused}
    >
      {children}
    </BorderBeam>
  );
}
