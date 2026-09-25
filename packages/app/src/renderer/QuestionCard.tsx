import { useState } from "react";
import { AgentAvatar } from "./agent-avatar";
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
 * on. Single single-select question: a click (or ⌘1..9) answers instantly.
 * Several single-select questions: pick one per question and the card sends
 * itself when the last one is chosen. Any multi-select question: its options
 * are checkboxes (tick as many as apply) and a Send button submits once every
 * question has at least one pick. Clicking the card background jumps to the
 * terminal.
 */
export function QuestionCard({
  session,
  onJump,
  onAnswer,
}: {
  session: SessionSnapshot;
  onJump: (session: SessionSnapshot) => void;
  onAnswer: (session: SessionSnapshot, selections: number[][]) => void;
}) {
  const q = session.pending_question;
  // The picks per sub-question. Keyed remount (in App) resets this whenever a
  // different question arrives.
  const [picked, setPicked] = useState<number[][]>(() => (q?.questions ?? []).map(() => []));
  if (!q) return null;
  const anyMulti = q.questions.some((sub) => sub.multiSelect === true);
  const instant = q.questions.length === 1 && !anyMulti;
  const complete = picked.length === q.questions.length && picked.every((p) => p.length > 0);

  const choose = (questionIndex: number, optionIndex: number) => {
    if (instant) {
      onAnswer(session, [[optionIndex]]);
      return;
    }
    const multi = q.questions[questionIndex]?.multiSelect === true;
    const next = picked.map((p, i) => {
      if (i !== questionIndex) return p;
      if (!multi) return [optionIndex];
      return p.includes(optionIndex) ? p.filter((o) => o !== optionIndex) : [...p, optionIndex].sort((a, b) => a - b);
    });
    setPicked(next);
    window.agentIsland?.haptic?.("tick");
    // Only all-single-select cards send themselves; a multi-select waits for Send.
    if (!anyMulti && next.every((p) => p.length > 0)) onAnswer(session, next);
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
          <AgentAvatar session={session} now={Date.now()} size={26} />
          {AGENT_ASKS[session.agent] ?? "Agent asks"}
        </span>
        <span className="approval-project">{projectName(session.cwd)}</span>
      </div>
      {q.questions.map((sub, qi) => {
        const multi = sub.multiSelect === true;
        return (
          <div className={`q-block${multi ? " multi" : ""}`} key={`${q.id}-${qi}`}>
            <div className="question-text">
              {sub.question}
              {multi && <span className="q-multi-tag">choose any</span>}
            </div>
            {sub.options.length > 0 && (
              <ul className="q-options" role={multi ? "group" : "radiogroup"} aria-label={sub.question}>
                {sub.options.slice(0, 9).map((label, i) => {
                  const on = picked[qi]?.includes(i) ?? false;
                  return (
                    <li key={`${q.id}-${qi}-${i}`}>
                      <button
                        type="button"
                        role={instant ? undefined : multi ? "checkbox" : "radio"}
                        aria-checked={instant ? undefined : on}
                        className={`q-option${on ? " picked" : ""}`}
                        onClick={(e) => {
                          e.stopPropagation();
                          choose(qi, i);
                        }}
                      >
                        {instant ? <kbd>⌘{i + 1}</kbd> : <span className={multi ? "q-check" : "q-dot"} />}
                        <span>{label}</span>
                      </button>
                    </li>
                  );
                })}
              </ul>
            )}
          </div>
        );
      })}
      <div className="q-footer">
        <div className="q-hint">
          {instant
            ? "⌘n or click to answer · click card to jump"
            : anyMulti
              ? "tick all that apply, then Send · click card to jump"
              : "pick one per question — sends itself · click card to jump"}
        </div>
        {anyMulti && (
          <button
            type="button"
            className="q-send"
            disabled={!complete}
            onClick={(e) => {
              e.stopPropagation();
              if (complete) onAnswer(session, picked);
            }}
          >
            Send
          </button>
        )}
      </div>
    </div>
  );
}
