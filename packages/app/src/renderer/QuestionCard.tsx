import type { SessionSnapshot } from "@agent-island/shared";

function projectName(cwd: string): string {
  const parts = cwd.split("/").filter(Boolean);
  return parts[parts.length - 1] ?? cwd;
}

/**
 * "Claude asks" — a multiple-choice question Claude is waiting on. The CLI owns
 * the actual input, so this card shows the question and jumps you to the
 * terminal to answer (honest v1 — no remote answering).
 */
export function QuestionCard({
  session,
  onJump,
}: {
  session: SessionSnapshot;
  onJump: (session: SessionSnapshot) => void;
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
          Claude asks
        </span>
        <span className="approval-project">{projectName(session.cwd)}</span>
      </div>
      <div className="question-text">{q.question}</div>
      {q.options.length > 0 && (
        <ul className="q-options">
          {q.options.map((label, i) => (
            <li key={`${q.id}-${i}`}>
              <kbd>{i + 1}</kbd>
              <span>{label}</span>
            </li>
          ))}
        </ul>
      )}
      <div className="q-hint">answer in the terminal · click to jump</div>
    </div>
  );
}
