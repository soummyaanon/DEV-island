import { useCallback, useEffect, useRef, useState, type RefObject } from "react";
import type { SessionSnapshot } from "@agent-island/shared";

/**
 * Accessibility primitives shared by the overlay.
 *
 * The overlay is click-through and non-focusable so it never steals focus from
 * a terminal, which makes it unreachable by VoiceOver by default. Everything
 * needed to reach in deliberately lives here rather than scattered through
 * components.
 *
 * Reduced motion is handled entirely in CSS for now — every animation in the
 * island is declarative, so the media query is sufficient. A JS-side hook only
 * becomes necessary once something *schedules* motion from a timer.
 */

/** Everything focusable inside a container, in tab order. */
function focusableWithin(root: HTMLElement): HTMLElement[] {
  const selector = 'button:not([disabled]), [href], input:not([disabled]), [tabindex]:not([tabindex="-1"])';
  return Array.from(root.querySelectorAll<HTMLElement>(selector)).filter(
    (el) => el.offsetParent !== null || el === document.activeElement,
  );
}

/**
 * Trap Tab inside `ref` while `active`, and focus its first control on entry.
 *
 * VoiceOver users reach the island through a global shortcut, so once they're
 * in, Tab must not wander off into a window that is otherwise invisible to
 * them. `onExit` runs on Escape.
 */
export function useFocusTrap(
  ref: RefObject<HTMLElement | null>,
  active: boolean,
  onExit: () => void,
): void {
  useEffect(() => {
    const root = ref.current;
    if (!active || !root) return;

    // Let the panel finish expanding before grabbing focus, or we'd focus a
    // control that is still zero-height and scroll the window oddly.
    const focusFirst = requestAnimationFrame(() => {
      focusableWithin(root)[0]?.focus();
    });

    const onKeyDown = (e: KeyboardEvent) => {
      if (e.key === "Escape") {
        e.preventDefault();
        onExit();
        return;
      }
      if (e.key !== "Tab") return;
      const items = focusableWithin(root);
      if (items.length === 0) return;
      const first = items[0];
      const last = items[items.length - 1];
      const current = document.activeElement as HTMLElement | null;
      // Wrap at both ends; also catches focus having escaped the panel entirely.
      if (e.shiftKey && (current === first || !root.contains(current))) {
        e.preventDefault();
        last.focus();
      } else if (!e.shiftKey && (current === last || !root.contains(current))) {
        e.preventDefault();
        first.focus();
      }
    };

    document.addEventListener("keydown", onKeyDown);
    return () => {
      cancelAnimationFrame(focusFirst);
      document.removeEventListener("keydown", onKeyDown);
    };
  }, [ref, active, onExit]);
}

/**
 * A polite and an assertive live region, with the message cleared after it has
 * been read.
 *
 * Two regions because the urgency genuinely differs: a session finishing can
 * wait for a gap in speech, an agent blocking on a permission cannot. Repeats
 * are re-announced by appending a zero-width space, since setting a live region
 * to the string it already holds says nothing.
 */
export function useAnnouncer(): {
  polite: string;
  assertive: string;
  announce: (message: string, urgency?: "polite" | "assertive") => void;
} {
  const [polite, setPolite] = useState("");
  const [assertive, setAssertive] = useState("");
  const repeats = useRef(0);

  const announce = useCallback((message: string, urgency: "polite" | "assertive" = "polite") => {
    if (!message) return;
    repeats.current = (repeats.current + 1) % 2;
    const text = repeats.current ? `${message}​` : message;
    if (urgency === "assertive") setAssertive(text);
    else setPolite(text);
  }, []);

  return { polite, assertive, announce };
}

export interface TransitionCounts {
  done: number;
  failed: number;
  questions: number;
  actions: number;
  /** Project name, used only when a single session transitioned. */
  only: string;
}

/**
 * One sentence for a whole snapshot's worth of transitions.
 *
 * Announcing per session would talk over itself when several agents finish
 * together, so the batch is summarised instead — named when it's a single
 * session, counted when it isn't. Anything blocking on the human is assertive;
 * everything else waits for a gap in speech.
 */
export function summarizeTransitions(
  counts: TransitionCounts,
): { message: string; urgency: "polite" | "assertive" } | null {
  const total = counts.done + counts.failed + counts.questions + counts.actions;
  if (total === 0) return null;

  const subject = (n: number, verb: string) =>
    total === 1 && counts.only ? `${counts.only} ${verb}` : `${n} ${n === 1 ? "session" : "sessions"} ${verb}`;

  const parts: string[] = [];
  if (counts.questions > 0) parts.push(subject(counts.questions, "is asking a question"));
  if (counts.actions > 0) parts.push(subject(counts.actions, "needs you"));
  if (counts.failed > 0) parts.push(subject(counts.failed, "failed"));
  if (counts.done > 0) parts.push(subject(counts.done, "finished"));

  return {
    message: parts.join(", "),
    urgency: counts.questions > 0 || counts.actions > 0 ? "assertive" : "polite",
  };
}

const STATE_WORDS: Record<string, string> = {
  working: "working",
  starting: "starting",
  "waiting-for-approval": "waiting for you",
  done: "finished",
  failed: "failed",
  idle: "idle",
};

function projectName(cwd: string): string {
  const parts = cwd.split("/").filter(Boolean);
  return parts[parts.length - 1] ?? cwd;
}

/**
 * The spoken description of a session row. Deliberately front-loads project and
 * state — the two things a listener needs before deciding to keep listening.
 */
export function describeSession(session: SessionSnapshot, elapsedLabel: string): string {
  const state = STATE_WORDS[session.state] ?? session.state;
  return [projectName(session.cwd), state, session.title, elapsedLabel]
    .filter((part) => part !== "")
    .join(", ");
}
