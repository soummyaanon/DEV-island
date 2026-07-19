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
 * "Claude/Codex asks" — a multiple-choice question the agent is waiting on.
 * ⌘1..⌘9 (or clicking an option) types the option number into the terminal
 * (iTerm2; elsewhere it jumps you there to answer). Clicking the card jumps.
 */
export function QuestionCard({
  session,
  onJump,
  onAnswer,
}: {
  session: SessionSnapshot;
  onJump: (session: SessionSnapshot) => void;
  onAnswer: (session: SessionSnapshot, digit: number) => void;
}) {
  const q = session.pending_question;
  if (!q) return null;

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
      <div className="question-text">{q.question}</div>
      {q.options.length > 0 && (
        <ul className="q-options">
          {q.options.slice(0, 9).map((label, i) => (
            <li
              key={`${q.id}-${i}`}
              className="q-option"
              onClick={(e) => {
                e.stopPropagation();
                onAnswer(session, i + 1);
              }}
            >
              <kbd>⌘{i + 1}</kbd>
              <span>{label}</span>
            </li>
          ))}
        </ul>
      )}
      <div className="q-hint">
        {q.options.length > 0 ? "⌘n or click to answer · " : ""}click card to jump
      </div>
    </div>
  );
}
