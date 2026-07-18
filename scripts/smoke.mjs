#!/usr/bin/env node
// Smoke test for agentislandd. Assumes the daemon is already running.
// Exercises the full pipeline: HTTP ingest -> state machine -> WS fan-out ->
// snapshot/ring-buffer reads. Exits non-zero if any check fails.
//
// Usage:  node scripts/smoke.mjs
// Env:    AGENT_ISLAND_HOST (127.0.0.1), AGENT_ISLAND_PORT (7433),
//         AGENT_ISLAND_TOKEN (optional; required when the daemon is strict)

const host = process.env.AGENT_ISLAND_HOST ?? "127.0.0.1";
const port = process.env.AGENT_ISLAND_PORT ?? "7433";
const token = process.env.AGENT_ISLAND_TOKEN;
const base = `http://${host}:${port}`;
const wsUrl = `ws://${host}:${port}/stream`;

const results = [];
function check(name, ok, detail = "") {
  results.push(ok);
  console.log(`${ok ? "✓" : "✗"} ${name}${detail ? ` — ${detail}` : ""}`);
}
const wait = (ms) => new Promise((r) => setTimeout(r, ms));
const timeout = (ms) =>
  new Promise((_, reject) => setTimeout(() => reject(new Error("timeout")), ms));

async function main() {
  // 1. health
  let health;
  try {
    const res = await fetch(`${base}/health`);
    health = await res.json();
    check("GET /health returns ok", res.ok && health.status === "ok", JSON.stringify(health));
  } catch (err) {
    check("GET /health returns ok", false, String(err));
    return finish();
  }

  // 2. connect WS, capturing every message (listener attached before open)
  const ws = new WebSocket(wsUrl);
  const messages = [];
  const eventReceived = new Promise((resolve) => {
    ws.addEventListener("message", (ev) => {
      const msg = JSON.parse(ev.data);
      messages.push(msg);
      if (msg.type === "event") resolve(msg);
    });
  });
  try {
    await Promise.race([
      new Promise((resolve, reject) => {
        ws.addEventListener("open", resolve);
        ws.addEventListener("error", reject);
      }),
      timeout(3000),
    ]);
  } catch {
    /* fall through; the connect check reports the failure */
  }
  check("WS /stream connects", ws.readyState === WebSocket.OPEN);
  await wait(150);
  check("WS receives initial snapshot", messages.some((m) => m.type === "snapshot"));

  // 3. POST a sample event
  const sample = {
    agent: "claude-code",
    session_id: `smoke-${process.pid}-${results.length}`,
    cwd: "/tmp/agent-island-smoke",
    type: "session_started",
    title: "smoke test session",
  };
  const headers = { "content-type": "application/json" };
  if (token) headers["x-agent-island-token"] = token;
  const postRes = await fetch(`${base}/events`, {
    method: "POST",
    headers,
    body: JSON.stringify(sample),
  });
  const posted = await postRes.json().catch(() => ({}));
  check(
    "POST /events accepted",
    postRes.status >= 200 && postRes.status < 300 && posted.ok === true,
    `status ${postRes.status}`,
  );
  check("daemon mints id + timestamp", Boolean(posted.event?.id && posted.event?.timestamp));
  check(
    "state machine: session_started -> starting",
    posted.session?.state === "starting",
    posted.session?.state,
  );

  // 4. WS pushes the event
  try {
    const msg = await Promise.race([eventReceived, timeout(3000)]);
    check("WS /stream pushes the event", msg?.event?.session_id === sample.session_id);
  } catch {
    check("WS /stream pushes the event", false, "timed out");
  }
  ws.close();

  // 5. snapshot + ring buffer reflect it
  const sessions = await fetch(`${base}/sessions`).then((r) => r.json());
  const found = sessions.sessions?.find((s) => s.session_id === sample.session_id);
  check("GET /sessions shows the session", Boolean(found), found ? `state=${found.state}` : "missing");

  const events = await fetch(`${base}/events`).then((r) => r.json());
  check(
    "GET /events ring buffer has it",
    Boolean(events.events?.some((e) => e.session_id === sample.session_id)),
  );

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
