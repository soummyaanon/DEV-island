import { useState } from "react";
import type { SessionSnapshot } from "@agent-island/shared";

const AGENT_ASKS: Record<string, string> = {
  "claude-code": "Claude asks",
  codex: "Codex asks",
  cursor: "Cursor asks",
};

function projectName(cwd: string): string {
  const parts = cwd.split("/").filter(Boolean);
  return parts[parts.length - 1] ?? cwd;
}

/**
 * "Claude/Codex asks" — the multiple-choice question(s) the agent is waiting
 * on. Single question: a click (or ⌘1..9) answers instantly. Several
 * questions: pick one option per question and the card submits itself when
 * the last one is chosen. Clicking the card background jumps to the terminal.
 */
export function QuestionCard({
  session,
  onJump,
  onAnswer,
}: {
  session: SessionSnapshot;
  onJump: (session: SessionSnapshot) => void;
  onAnswer: (session: SessionSnapshot, options: number[]) => void;
}) {
  const q = session.pending_question;
  // One selection slot per sub-question; -1 = not chosen yet. Keyed remount
  // (below) resets this whenever a different question arrives.
  const [picked, setPicked] = useState<number[]>(() =>
    new Array(q?.questions.length ?? 0).fill(-1),
  );
  if (!q) return null;
  const single = q.questions.length === 1;

  const choose = (questionIndex: number, optionIndex: number) => {
    if (single) {
      onAnswer(session, [optionIndex]);
      return;
    }
    const next = [...picked];
    next[questionIndex] = optionIndex;
    setPicked(next);
    if (next.every((p) => p >= 0)) onAnswer(session, next);
  };

  return (
    <div
      className="question"
      onClick={(e) => {
        e.stopPropagation();
        onJump(session);
      }}
    >
      <div className="approval-top">
        <span className="approval-kicker">
          <span className="approval-mark ask" />
          {AGENT_ASKS[session.agent] ?? "Agent asks"}
        </span>
        <span className="approval-project">{projectName(session.cwd)}</span>
      </div>
      {q.questions.map((sub, qi) => (
        <div className="q-block" key={`${q.id}-${qi}`}>
          <div className="question-text">{sub.question}</div>
          {sub.options.length > 0 && (
            <ul className="q-options">
              {sub.options.slice(0, 9).map((label, i) => (
                <li key={`${q.id}-${qi}-${i}`}>
                  <button
                    type="button"
                    className={`q-option${picked[qi] === i ? " picked" : ""}`}
                    onClick={(e) => {
                      e.stopPropagation();
                      choose(qi, i);
                    }}
                  >
                    {single ? <kbd>⌘{i + 1}</kbd> : <span className="q-dot" />}
                    <span>{label}</span>
                  </button>
                </li>
              ))}
            </ul>
          )}
        </div>
      ))}
      <div className="q-hint">
        {single
          ? "⌘n or click to answer · click card to jump"
          : "pick one per question — sends itself · click card to jump"}
      </div>
    </div>
  );
}
