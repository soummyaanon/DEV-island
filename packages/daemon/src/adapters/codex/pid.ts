import { execFile } from "node:child_process";

/**
 * Best-effort: which process is this Codex session? Codex has no hook to tell
 * us, so ask who holds the rollout file open, and failing that accept a lone
 * `codex` process. Anything ambiguous is null — no meter beats a wrong one.
 */

const PID = /^\d{1,7}$/;

/** Pure: choose a PID from `lsof -t <file>` and `pgrep -x codex` outputs. */
export function pickPid(lsofOut: string, pgrepOut: string): number | null {
  const held = lsofOut.split("\n").map((l) => l.trim()).filter((l) => PID.test(l));
  if (held.length > 0) return Number(held[0]);
  const lone = pgrepOut.split("\n").map((l) => l.trim()).filter((l) => PID.test(l));
  return lone.length === 1 ? Number(lone[0]) : null;
}

function run(cmd: string, args: string[]): Promise<string> {
  return new Promise((resolve) => {
    execFile(cmd, args, { timeout: 2000 }, (err, stdout) => resolve(err ? "" : String(stdout)));
  });
}

export async function resolveCodexPid(rolloutFile: string): Promise<number | null> {
  const lsof = await run("lsof", ["-t", rolloutFile]);
  const pgrep = lsof.trim() ? "" : await run("pgrep", ["-x", "codex"]);
  return pickPid(lsof, pgrep);
}
