import type { ReactNode } from "react";
import { BorderBeam } from "border-beam";

/**
 * The island's text fields wear a soft sunset pulse instead of a focus ring:
 * it fades in when you start typing and out when you leave. The field
 * itself stays a quiet dark pill; the beam is the only thing that says "live".
 */
export function FieldBeam({
  focused,
  paused = false,
  children,
}: {
  focused: boolean;
  paused?: boolean;
  children: ReactNode;
}) {
  return (
    <BorderBeam
      className="field-beam"
      size="pulse-inner"
      colorVariant="sunset"
      // Pure palette: the library's hue drift wanders off-colour on black.
      staticColors
      theme="dark"
      strength={0.35}
      borderRadius={14}
      active={focused && !paused}
    >
      {children}
    </BorderBeam>
  );
}
