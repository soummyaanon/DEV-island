import { app } from "electron";
import { spawn, type ChildProcessWithoutNullStreams } from "node:child_process";
import { existsSync } from "node:fs";
import { join } from "node:path";

/**
 * The native sidecar (`native/AgentIslandNative.swift`) — the few AppKit
 * surfaces Electron doesn't expose. One long-lived process fed newline
 * commands, because haptics need sub-10ms latency and an `osascript` round
 * trip costs 150ms+ plus a spawn.
 *
 * Absence is a FIRST-CLASS state, not an error: no Xcode CLT at build time, a
 * stripped binary, a quarantine flag, or a crash all resolve to `send()`
 * returning false. Callers degrade (haptics go inert) rather than handle
 * failures — which is why nothing here throws or rejects.
 */

let proc: ChildProcessWithoutNullStreams | null = null;
/** Spawn is attempted at most twice per run; a second death disables us. */
let spawnsLeft = 2;

/** Path to the compiled helper (dev vs packaged). */
function helperPath(): string {
  if (app.isPackaged) {
    // Placed here by electron-builder's extraResources.
    return join(process.resourcesPath, "native", "AgentIslandNative");
  }
  // dev: packages/app/out/main -> packages/app/native/AgentIslandNative
  return join(__dirname, "../../native/AgentIslandNative");
}

function spawnHelper(): ChildProcessWithoutNullStreams | null {
  if (spawnsLeft <= 0) return null;
  const path = helperPath();
  if (!existsSync(path)) {
    // Expected on a checkout built without swiftc — say it once, then stay quiet.
    if (spawnsLeft === 2) console.log(`[native] helper not built (${path}) — haptics inert`);
    spawnsLeft = 0;
    return null;
  }

  spawnsLeft -= 1;
  try {
    const child = spawn(path, [], { stdio: ["pipe", "pipe", "pipe"] });
    child.stdout.setEncoding("utf8");
    child.stderr.setEncoding("utf8");
    // The helper only ever answers "ok" / "pong" / "err ..."; surface errors
    // only, so a working install logs nothing.
    child.stdout.on("data", (chunk: string) => {
      for (const line of chunk.split("\n")) {
        if (line.startsWith("err ")) console.warn(`[native] ${line}`);
      }
    });
    child.on("error", (err) => {
      console.warn(`[native] helper error: ${err.message}`);
      proc = null;
    });
    child.on("exit", (code) => {
      console.log(`[native] helper exited (code ${code})`);
      proc = null;
    });
    // A dead pipe must never reach the parent as an unhandled 'error'.
    child.stdin.on("error", () => {
      proc = null;
    });
    console.log(`[native] helper ready: ${path}`);
    return child;
  } catch (err) {
    console.warn(`[native] spawn failed: ${String(err)}`);
    return null;
  }
}

/** Send one command. False means the helper is unavailable — never an error. */
export function send(command: string): boolean {
  if (!proc) proc = spawnHelper();
  if (!proc?.stdin.writable) return false;
  try {
    return proc.stdin.write(`${command}\n`);
  } catch {
    proc = null;
    return false;
  }
}

/**
 * Whether the helper looks usable. Only inspects the compiled binary and the
 * remaining spawn budget — deliberately does NOT spawn, so callers can ask
 * cheaply (e.g. to render a Settings hint) without starting a process.
 */
export function isAvailable(): boolean {
  if (proc?.stdin.writable) return true;
  return spawnsLeft > 0 && existsSync(helperPath());
}

/** Ask the helper to exit, then drop it. Safe to call when never spawned. */
export function stopHelper(): void {
  if (!proc) return;
  // Closing stdin is the documented shutdown path; `quit` just makes it prompt.
  send("quit");
  proc.stdin.end();
  proc = null;
  spawnsLeft = 0;
}
