import type { PendingApproval, SessionSnapshot, ApprovalDecision } from "@agent-island/shared";
import { AgentAvatar } from "./agent-avatar";
import { renderMarkdown } from "./markdown";

function projectName(cwd: string): string {
  const parts = cwd.split("/").filter(Boolean);
  return parts[parts.length - 1] ?? cwd;
}

function baseName(p: string): string {
  return p.split("/").filter(Boolean).slice(-2).join("/") || p;
}

/** Human title for the request, e.g. "Edit middleware.ts" / "Run command". */
function title(a: PendingApproval): string {
  const input = a.tool_input ?? {};
  const file = typeof input.file_path === "string" ? baseName(input.file_path) : null;
  switch (a.tool_name) {
    case "Edit":
    case "MultiEdit":
      return file ? `Edit ${file}` : "Edit file";
    case "Write":
      return file ? `Write ${file}` : "Write file";
    case "Read":
      return file ? `Read ${file}` : "Read file";
    case "Bash":
      return "Run command";
    case "ExitPlanMode":
      return "Review plan";
    default:
      return a.tool_name;
  }
}

/** A red/green diff or code block from the tool input. */
function ApprovalBody({ approval }: { approval: PendingApproval }) {
  const input = approval.tool_input ?? {};

  if (approval.plan) {
    return (
      <div
        className="approval-body"
        dangerouslySetInnerHTML={{ __html: renderMarkdown(approval.plan) }}
      />
    );
  }

  const oldStr = typeof input.old_string === "string" ? input.old_string : "";
  const newStr = typeof input.new_string === "string" ? input.new_string : "";
  const content = typeof input.content === "string" ? input.content : "";
  const removed = oldStr ? oldStr.split("\n") : [];
  const added = (newStr || content) ? (newStr || content).split("\n") : [];

  if (removed.length || added.length) {
    return (
      <div className="approval-body">
        <pre className="diff">
          {removed.map((line, i) => (
            <div key={`d${i}`} className="diff-del">
              {`- ${line}`}
            </div>
          ))}
          {added.map((line, i) => (
            <div key={`a${i}`} className="diff-add">
              {`+ ${line}`}
            </div>
          ))}
        </pre>
        <div className="diff-stat">
          <span className="add">+{added.length}</span> <span className="del">-{removed.length}</span>
        </div>
      </div>
    );
  }

  if (typeof input.command === "string") {
    return (
      <div className="approval-body">
        <pre className="cmd">{input.command}</pre>
      </div>
    );
  }

  const keys = Object.keys(input);
  return (
    <div className="approval-body">
      <pre className="cmd">{keys.length ? JSON.stringify(input, null, 2) : "no details"}</pre>
    </div>
  );
}

export function ApprovalCard({
  session,
  onDecide,
}: {
  session: SessionSnapshot;
  onDecide: (id: string, decision: ApprovalDecision) => void;
}) {
  const a = session.pending_approval;
  if (!a) return null;

  return (
    <div className="approval" onClick={(e) => e.stopPropagation()}>
      <div className="approval-top">
        <span className="approval-kicker">
          <AgentAvatar session={session} now={Date.now()} size={26} />
          Permission Request
        </span>
        <span className="approval-project">{projectName(session.cwd)}</span>
      </div>
      <div className="approval-title">{title(a)}</div>

      <ApprovalBody approval={a} />

      <div className="approval-actions">
        <button type="button" className="btn deny" onClick={() => onDecide(a.id, "deny")}>
          Deny <kbd>⌘N</kbd>
        </button>
        <button type="button" className="btn allow" onClick={() => onDecide(a.id, "allow")}>
          Allow <kbd>⌘Y</kbd>
        </button>
      </div>
    </div>
  );
}
