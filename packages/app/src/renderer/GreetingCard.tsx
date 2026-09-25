import { useEffect, useState } from "react";
import { BotAvatar, type BotAvatarType } from "bot-avatars";

/**
 * The hello. The crew pops up one by one and hops, the title lands, and the
 * line — written by Apple's on-device model — types itself in. Click it (or
 * let it be) and the island folds back to the notch.
 */

const CREW: Array<{ type: BotAvatarType; seed: number }> = [
  { type: "clover", seed: 0.12 },
  { type: "star", seed: 0.47 },
  { type: "alien", seed: 0.81 },
];

/** Typing speed for the line, per character. */
const TYPE_MS = 28;

/** How long the hello stays up: long enough to read the line, then a beat. */
export function greetingDuration(line: string): number {
  return Math.min(12_000, 4200 + line.length * 55);
}

export function GreetingCard({
  title,
  line,
  ai,
  paused,
  onDismiss,
}: {
  title: string;
  line: string;
  ai: boolean;
  paused: boolean;
  onDismiss: () => void;
}) {
  const [shown, setShown] = useState(paused ? line.length : 0);
  useEffect(() => {
    if (paused) {
      setShown(line.length);
      return;
    }
    setShown(0);
    // A short pause so the title lands first.
    let id = 0;
    const start = window.setTimeout(() => {
      id = window.setInterval(() => {
        setShown((n) => {
          if (n >= line.length) {
            window.clearInterval(id);
            return n;
          }
          return n + 1;
        });
      }, TYPE_MS);
    }, 450);
    return () => {
      window.clearTimeout(start);
      window.clearInterval(id);
    };
  }, [line, paused]);

  return (
    <button
      type="button"
      className="greet-card"
      aria-label={`${title}. ${line}`}
      onClick={(e) => {
        e.stopPropagation();
        onDismiss();
      }}
    >
      <span className="greet-crew" aria-hidden>
        {CREW.map((b, i) => (
          <span className="greet-bot" style={{ animationDelay: `${i * 110}ms` }} key={b.type}>
            <BotAvatar
              type={b.type}
              size={30}
              state="working"
              seed={b.seed}
              theme="dark"
              whirl={1}
              jumpEvery={2.4}
              interactive={false}
              paused={paused}
              aria-hidden
            />
          </span>
        ))}
      </span>
      <span className="greet-text" aria-hidden>
        <b className="greet-title">{title}</b>
        <span className="greet-line">
          {line.slice(0, shown)}
          {shown < line.length && <i className="greet-caret" />}
        </span>
        {ai && shown >= line.length && <span className="greet-by">✦ Apple Intelligence</span>}
      </span>
    </button>
  );
}
