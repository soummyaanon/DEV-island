import { app, utilityProcess, type UtilityProcess } from "electron";
import { join } from "node:path";

let proc: UtilityProcess | null = null;

/** Path to the self-contained daemon bundle (dev vs packaged). */
function daemonPath(): string {
  if (app.isPackaged) {
    // Copied here by electron-builder's extraResources.
    return join(process.resourcesPath, "daemon", "main.cjs");
  }
  // dev: packages/app/out/main -> packages/daemon/dist/main.cjs
  return join(__dirname, "../../../daemon/dist/main.cjs");
}

async function isDaemonUp(port = 7433): Promise<boolean> {
  try {
    const res = await fetch(`http://127.0.0.1:${port}/health`, {
      signal: AbortSignal.timeout(1200),
    });
    return res.ok;
  } catch {
    return false;
  }
}

/**
 * Ensure a daemon is running: reuse one that's already listening (e.g. a dev
 * `pnpm dev`), otherwise spawn our bundled daemon as a Node utility process so
 * the app is one launch, no separate terminal.
 */
export async function ensureDaemon(): Promise<void> {
  if (await isDaemonUp()) {
    console.log("[daemon-manager] reusing daemon already on :7433");
    return;
  }
  const path = daemonPath();
  // Cap the daemon's V8 heap — it only holds recent events + session state.
  proc = utilityProcess.fork(path, [], { execArgv: ["--max-old-space-size=48"] });
  proc.on("exit", (code) => {
    console.log(`[daemon-manager] daemon exited (code ${code})`);
    proc = null;
  });
  console.log(`[daemon-manager] spawned daemon: ${path}`);
}

/** Stop the daemon we spawned (no-op if we're reusing an external one). */
export function stopDaemon(): void {
  proc?.kill();
  proc = null;
}
