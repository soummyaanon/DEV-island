import type { CSSProperties } from "react";
import type { SessionSnapshot, SessionState } from "@agent-island/shared";
import { describeSession } from "./a11y";

const AGENT_LABEL: Record<string, string> = {
  "claude-code": "claude",
  codex: "codex",
  cursor: "cursor",
};

const MODE_LABEL: Record<string, string> = {
  default: "default",
  plan: "plan",
  acceptEdits: "accept",
  auto: "auto",
  dontAsk: "dont ask",
  bypassPermissions: "bypass",
  // Cursor composer modes (surfaced via session meta.permission_mode)
  agent: "agent",
  ask: "ask",
  edit: "edit",
};

/** Friendly names for the app hosting the session's terminal (bundle id). */
const HOST_LABEL: Record<string, string> = {
  "com.todesktop.230313mzl4w4u92": "cursor",
  "com.microsoft.VSCode": "vscode",
  "com.googlecode.iterm2": "iterm",
  "com.apple.Terminal": "terminal",
  "dev.warp.Warp-Stable": "warp",
  "com.mitchellh.ghostty": "ghostty",
  "com.github.wez.wezterm": "wezterm",
};

/** Where the session lives, derived dynamically — never guessed from the agent. */
function hostLabel(session: SessionSnapshot): string {
  const bundleId = metaString(session, "app_bundle_id");
  if (bundleId) {
    return HOST_LABEL[bundleId] ?? (bundleId.split(".").pop() ?? "").toLowerCase();
  }
  const term = metaString(session, "term_program");
  if (term === "iTerm.app") return "iterm";
  if (term === "Apple_Terminal") return "terminal";
  if (term === "vscode") return "vscode";
  return "";
}

function projectName(cwd: string): string {
  const parts = cwd.split("/").filter(Boolean);
  return parts[parts.length - 1] ?? cwd;
}

function elapsed(fromIso: string, now: number): string {
  const total = Math.max(0, Math.floor((now - Date.parse(fromIso)) / 1000));
  const hours = Math.floor(total / 3600);
  const minutes = Math.floor((total % 3600) / 60);
  if (hours > 0) return `${hours}h ${minutes}m`;
  if (minutes > 0) return `${minutes}m`;
  return `${total}s`;
}

function metaString(session: SessionSnapshot, key: string): string {
  const v = session.meta?.[key];
  return typeof v === "string" ? v : "";
}

export function StatusDot({ state }: { state: SessionState }) {
  return <span className={`dot state-${state}`} aria-hidden />;
}

export function SessionRow({
  session,
  now,
  index = 0,
  onJump,
}: {
  session: SessionSnapshot;
  now: number;
  /** Position in the list — drives the entrance stagger (`--i`). */
  index?: number;
  onJump: (session: SessionSnapshot) => void;
}) {
  const term = metaString(session, "term_program");
  const mode = metaString(session, "permission_mode");
  const model = metaString(session, "model");
  const agent = AGENT_LABEL[session.agent] ?? session.agent;
  // Show the host app when it isn't obvious — "claude · cursor" tells you the
  // session lives in Cursor's terminal, and jump will bring Cursor back.
  const host = hostLabel(session);
  const showHost = host !== "" && host !== agent;

  const elapsedLabel = elapsed(session.started_at, now);
  const context =
    agent +
    (showHost ? ` · ${host}` : "") +
    (model ? ` · ${model}` : "") +
    (mode ? ` · ${MODE_LABEL[mode] ?? mode}` : "");

  // A <button>, not a clickable <li>: this row was previously unreachable by
  // keyboard or VoiceOver entirely. The inner spans are aria-hidden because the
  // composed label reads better than four fragments in DOM order.
  return (
    <li>
      <button
        type="button"
        className={`row state-${session.state}`}
        style={{ "--i": index } as CSSProperties}
        title={term ? `Jump to ${projectName(session.cwd)} in ${term}` : "Jump to terminal"}
        aria-label={describeSession(session, elapsedLabel)}
        onClick={(e) => {
          e.stopPropagation();
          window.agentIsland.haptic("tick");
          onJump(session);
        }}
      >
        <StatusDot state={session.state} />
        <div className="row-main" aria-hidden>
          <div className="row-heading">
            <span className="project">{projectName(session.cwd)}</span>
            <span className="elapsed">{elapsedLabel}</span>
          </div>
          <div className="row-detail">
            <span className="activity">{session.title}</span>
            <span className="row-context">{context}</span>
          </div>
        </div>
      </button>
    </li>
  );
}
