import { execFile } from "node:child_process";

/**
 * What your agents cost right now: CPU and memory summed over each agent's
 * process tree (the agent, its shells, the test runner it spawned…).
 *
 * One `ps -axo pid,ppid,%cpu,rss` (~10ms for ~900 processes) every two
 * seconds — and ONLY while the panel is open, the setting is on, and at least
 * one session has a known root PID. Nothing polls unseen.
 */

export interface ProcRow {
  pid: number;
  ppid: number;
  cpu: number;
  rssKb: number;
}

export interface ProcTotals {
  /** Percent of one core, summed — 250 means two and a half cores busy. */
  cpu: number;
  rssMb: number;
  procs: number;
}

export const PROC_STATS_INTERVAL_MS = 2000;

/** Parse `ps -axo pid,ppid,%cpu,rss`. Header and malformed lines are skipped. */
export function parsePs(stdout: string): ProcRow[] {
  const rows: ProcRow[] = [];
  for (const line of stdout.split("\n")) {
    const parts = line.trim().split(/\s+/);
    if (parts.length < 4) continue;
    const pid = Number(parts[0]);
    const ppid = Number(parts[1]);
    const cpu = Number(parts[2]);
    const rssKb = Number(parts[3]);
    if (![pid, ppid, cpu, rssKb].every(Number.isFinite)) continue;
    rows.push({ pid, ppid, cpu, rssKb });
  }
  return rows;
}

/**
 * Sum a root's whole descendant tree. Null when the root is gone — a PID
 * reused by some unrelated process after the agent exits must not attribute a
 * stranger's load to a session.
 */
export function subtreeTotals(rows: ProcRow[], rootPid: number): ProcTotals | null {
  const byPid = new Map<number, ProcRow>();
  const children = new Map<number, ProcRow[]>();
  for (const row of rows) {
    byPid.set(row.pid, row);
    const list = children.get(row.ppid);
    if (list) list.push(row);
    else children.set(row.ppid, [row]);
  }
  if (!byPid.has(rootPid)) return null;

  const seen = new Set<number>();
  const stack = [rootPid];
  let cpu = 0;
  let rssKb = 0;
  while (stack.length > 0) {
    const pid = stack.pop() as number;
    if (seen.has(pid)) continue; // cycle guard — never observed, cheap to survive
    seen.add(pid);
    const row = byPid.get(pid);
    if (!row) continue;
    cpu += row.cpu;
    rssKb += row.rssKb;
    for (const child of children.get(pid) ?? []) stack.push(child.pid);
  }
  return { cpu: Math.round(cpu), rssMb: Math.round(rssKb / 1024), procs: seen.size };
}

/** Session key → root PID, as known right now. */
export type RootsProvider = () => Map<string, number>;

type Listener = (stats: Record<string, ProcTotals | null>) => void;

let enabled = true;
let active = false;
let roots: RootsProvider = () => new Map();
let listener: Listener | null = null;
let timer: ReturnType<typeof setTimeout> | null = null;
let inFlight = false;

function readPs(): Promise<string> {
  return new Promise((resolve) => {
    execFile("ps", ["-axo", "pid,ppid,%cpu,rss"], { timeout: 3000, maxBuffer: 4 * 1024 * 1024 }, (err, stdout) =>
      resolve(err ? "" : stdout),
    );
  });
}

async function sample(): Promise<void> {
  timer = null;
  if (!enabled || !active || inFlight) return;
  const wanted = roots();
  if (wanted.size === 0) return;
  inFlight = true;
  try {
    const rows = parsePs(await readPs());
    const stats: Record<string, ProcTotals | null> = {};
    for (const [key, pid] of wanted) stats[key] = subtreeTotals(rows, pid);
    listener?.(stats);
  } finally {
    inFlight = false;
  }
  schedule();
}

function schedule(): void {
  if (timer || !enabled || !active) return;
  timer = setTimeout(() => void sample(), PROC_STATS_INTERVAL_MS);
}

export function startProcStats(options: { enabled: boolean; roots: RootsProvider; onStats: Listener }): void {
  enabled = options.enabled;
  roots = options.roots;
  listener = options.onStats;
}

/** The panel opened or closed. Sampling runs only while it is open. */
export function setProcStatsActive(on: boolean): void {
  active = on;
  if (on) void sample();
  else if (timer) {
    clearTimeout(timer);
    timer = null;
  }
}

export function setProcStatsEnabled(on: boolean): void {
  enabled = on;
  if (!on) {
    if (timer) clearTimeout(timer);
    timer = null;
    listener?.({});
  } else if (active) {
    void sample();
  }
}
