#!/usr/bin/env node
// Tail the daemon's live event stream, one line per event. Ctrl-C to stop.
// Usage: node scripts/ws-tail.mjs   (env: AGENT_ISLAND_HOST/PORT)

const host = process.env.AGENT_ISLAND_HOST ?? "127.0.0.1";
const port = process.env.AGENT_ISLAND_PORT ?? "7433";
const short = (id) => (id ?? "").slice(0, 8);

const ws = new WebSocket(`ws://${host}:${port}/stream`);

ws.addEventListener("open", () => console.log(`[connected to ${host}:${port}/stream]`));
ws.addEventListener("error", (e) => console.error("[ws error]", e?.message ?? e));
ws.addEventListener("close", () => console.log("[stream closed]"));

ws.addEventListener("message", (ev) => {
  const msg = JSON.parse(ev.data);
  if (msg.type === "snapshot") {
    console.log(`[snapshot] ${msg.sessions.length} active session(s)`);
    for (const s of msg.sessions) {
      console.log(`  ${s.agent} ${short(s.session_id)} [${s.state}] ${s.title}`);
    }
  } else if (msg.type === "event") {
    const { event: e, session: s } = msg;
    const flag = s.requires_action ? " ⚠needs-action" : "";
    console.log(`[event] ${e.agent} ${short(e.session_id)} ${e.type} -> [${s.state}]${flag} | ${e.title}`);
  }
  // ping messages are ignored
});
