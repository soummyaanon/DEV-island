import type { PendingApproval, SessionSnapshot, ApprovalDecision } from "@agent-island/shared";
import { renderMarkdown } from "./markdown";

function projectName(cwd: string): string {
  const parts = cwd.split("/").filter(Boolean);
  return parts[parts.length - 1] ?? cwd;
}

/** Build reviewable markdown from a pending approval (plan text or tool input). */
function approvalMarkdown(a: PendingApproval): string {
  if (a.plan) return a.plan;
  const input = a.tool_input ?? {};
  if (typeof input.command === "string") return "```\n" + input.command + "\n```";
  if (typeof input.file_path === "string") return "`" + input.file_path + "`";
  const keys = Object.keys(input);
  if (keys.length === 0) return "_no details_";
  return "```json\n" + JSON.stringify(input, null, 2) + "\n```";
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
  const isPlan = a.tool_name === "ExitPlanMode" || Boolean(a.plan);

  return (
    // Stop clicks here from toggling the island's pin state.
    <div className="approval" onClick={(e) => e.stopPropagation()}>
      <div className="approval-head">
        <span className="approval-title">{isPlan ? "Review plan" : `Approve ${a.tool_name}`}</span>
        <span className="approval-project">{projectName(session.cwd)}</span>
      </div>
      <div
        className="approval-body"
        // Safe: renderMarkdown escapes all HTML before emitting its own tags.
        dangerouslySetInnerHTML={{ __html: renderMarkdown(approvalMarkdown(a)) }}
      />
      <div className="approval-actions">
        <button type="button" className="btn deny" onClick={() => onDecide(a.id, "deny")}>
          Deny
        </button>
        <button type="button" className="btn allow" onClick={() => onDecide(a.id, "allow")}>
          Approve
        </button>
      </div>
    </div>
  );
}
