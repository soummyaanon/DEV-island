#!/usr/bin/env node
// Smoke test for the Claude Code adapter. Assumes the daemon is running.
// POSTs the documented v2.1.x hook payloads to /events/claude/* and asserts the
// canonical mapping, state transitions, the empty-204 safety contract, and that
// the cwd-less Notification does NOT clobber the session's known directory.
//
// Usage: node scripts/claude-smoke.mjs   (env: AGENT_ISLAND_HOST/PORT/TOKEN)

const host = process.env.AGENT_ISLAND_HOST ?? "127.0.0.1";
const port = process.env.AGENT_ISLAND_PORT ?? "7433";
const token = process.env.AGENT_ISLAND_TOKEN;
const base = `http://${host}:${port}`;
const SID = `claude-smoke-${process.pid}`;
const CWD = "/Users/dev/my-project";

const results = [];
function check(name, ok, detail = "") {
  results.push(ok);
  console.log(`${ok ? "✓" : "✗"} ${name}${detail ? ` — ${detail}` : ""}`);
}

async function hook(slug, payload) {
  const headers = { "content-type": "application/json" };
  if (token) headers["x-agent-island-token"] = token;
  const res = await fetch(`${base}/events/claude/${slug}`, {
    method: "POST",
    headers,
    body: JSON.stringify(payload),
  });
  const body = await res.text();
  // The safety contract: monitoring endpoint must reply 204 with an empty body.
  check(`POST /events/claude/${slug} -> 204 empty`, res.status === 204 && body === "");
}

async function session() {
  const data = await fetch(`${base}/sessions`).then((r) => r.json());
  return data.sessions?.find((s) => s.session_id === SID);
}

async function main() {
  // SessionStart
  await hook("session-start", {
    session_id: SID,
    cwd: CWD,
    hook_event_name: "SessionStart",
    source: "startup",
    model: "claude-sonnet-5",
  });
  let s = await session();
  check("SessionStart -> starting", s?.state === "starting", s?.state);
  check("agent is claude-code", s?.agent === "claude-code");
  check("cwd captured", s?.cwd === CWD, s?.cwd);

  // PreToolUse
  await hook("pre-tool", {
    session_id: SID,
    cwd: CWD,
    hook_event_name: "PreToolUse",
    tool_name: "Bash",
    tool_input: { command: "npm test" },
  });
  s = await session();
  check("PreToolUse -> working", s?.state === "working", s?.state);
  check("title is tool name", s?.title === "Bash", s?.title);

  // PostToolUse
  await hook("post-tool", {
    session_id: SID,
    cwd: CWD,
    hook_event_name: "PostToolUse",
    tool_name: "Bash",
    tool_response: { stdout: "ok", stderr: "", exit_code: 0 },
  });
  s = await session();
  check("PostToolUse -> working", s?.state === "working", s?.state);

  // PermissionRequest
  await hook("permission-request", {
    session_id: SID,
    cwd: CWD,
    hook_event_name: "PermissionRequest",
    tool_name: "Bash",
    tool_input: { command: "rm -rf build" },
  });
  s = await session();
  check("PermissionRequest -> waiting-for-approval", s?.state === "waiting-for-approval", s?.state);
  check("PermissionRequest sets requires_action", s?.requires_action === true);

  // Notification WITHOUT cwd (the documented payload omits it)
  await hook("notification", {
    session_id: SID,
    transcript_path: "/x/transcript.jsonl",
    hook_event_name: "Notification",
    message: "Permission required to run Bash command",
    notification_type: "permission_prompt",
  });
  s = await session();
  check("Notification(permission_prompt) -> waiting-for-approval", s?.state === "waiting-for-approval", s?.state);
  check("cwd preserved despite cwd-less payload", s?.cwd === CWD, s?.cwd);

  // Stop
  await hook("stop", {
    session_id: SID,
    cwd: CWD,
    hook_event_name: "Stop",
    last_assistant_message: "all done",
    stop_reason: "end_turn",
  });
  s = await session();
  check("Stop -> done", s?.state === "done", s?.state);

  // Unknown/unmapped event is a safe no-op (still 204)
  await hook("post-tool", {
    session_id: SID,
    cwd: CWD,
    hook_event_name: "SomeFutureEvent",
  });

  // detail carried through into the ring buffer
  const events = await fetch(`${base}/events`).then((r) => r.json());
  const pre = events.events?.find((e) => e.session_id === SID && e.type === "tool_use");
  check("detail carries tool_input", pre?.detail?.tool_input?.command === "npm test");

  finish();
}

function finish() {
  const passed = results.filter(Boolean).length;
  console.log(`\n${passed}/${results.length} checks passed`);
  process.exit(passed === results.length ? 0 : 1);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
