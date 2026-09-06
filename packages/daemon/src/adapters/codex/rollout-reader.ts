import { open, readdir, readFile, stat } from "node:fs/promises";
import { join } from "node:path";
import type { EventInput, PendingQuestion } from "@agent-island/shared";
import {
  createCodexContext,
  extractCodexQuestion,
  mapCodexEntry,
  parseRolloutLine,
  type CodexSessionContext,
} from "./event-mapper";
import { resolveCodexPid } from "./pid";

/**
 * Where mapped events go. EventHub satisfies this via a two-line adapter in
 * main.ts; tests use an in-memory fake.
 */
export interface CodexSink {
  ingest(input: EventInput): void;
  setPendingQuestion(sessionId: string, question: PendingQuestion | null): void;
}

export interface CodexRolloutReaderOptions {
  /** How often attached files are stat-polled for appended bytes. */
  pollMs?: number;
  /** How often the sessions tree is rescanned for new/reactivated files. */
  scanMs?: number;
  /** Only files written within this window count as active. */
  activeMs?: number;
  log?: (message: string) => void;
}

interface TailState {
  ctx: CodexSessionContext;
  /** Byte just after the last processed newline. */
  offset: number;
  /** True while a request_user_input is unanswered. */
  questionPending: boolean;
}

const ROLLOUT_RE = /^rollout-.*\.jsonl$/;
const UUID_RE = /([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\.jsonl$/i;

/**
 * Tails Codex rollout logs (`$CODEX_HOME/sessions/…/rollout-*.jsonl`) and feeds
 * canonical events into the hub — the Codex counterpart of the Claude hook
 * routes. Strictly read-only and strictly non-fatal: Codex never knows we're
 * here, and any unreadable file / malformed line is skipped with at most a log
 * line. Plain stat-polling (no native watchers) keeps behavior deterministic
 * in the packaged daemon and in tests.
 */
export class CodexRolloutReader {
  private readonly pollMs: number;
  private readonly scanMs: number;
  private readonly activeMs: number;
  private readonly log: (message: string) => void;
  private readonly tails = new Map<string, TailState>();
  private pollTimer: ReturnType<typeof setInterval> | null = null;
  private scanTimer: ReturnType<typeof setInterval> | null = null;
  private busy = false;
  private stopped = false;

  constructor(
    private readonly codexHome: string,
    private readonly sink: CodexSink,
    options: CodexRolloutReaderOptions = {},
  ) {
    this.pollMs = options.pollMs ?? 1_500;
    this.scanMs = options.scanMs ?? 10_000;
    this.activeMs = options.activeMs ?? 600_000;
    this.log = options.log ?? (() => {});
  }

  async start(): Promise<void> {
    await this.scan();
    this.pollTimer = setInterval(() => void this.tick(false), this.pollMs);
    this.scanTimer = setInterval(() => void this.tick(true), this.scanMs);
  }

  stop(): void {
    this.stopped = true;
    if (this.pollTimer) clearInterval(this.pollTimer);
    if (this.scanTimer) clearInterval(this.scanTimer);
    this.pollTimer = null;
    this.scanTimer = null;
  }

  /** Serialize timer work so a slow disk can't stack overlapping passes. */
  private async tick(rescan: boolean): Promise<void> {
    if (this.busy || this.stopped) return;
    this.busy = true;
    try {
      if (rescan) await this.scan();
      await this.pollAttached();
    } catch (err) {
      this.log(`codex reader pass failed: ${String(err)}`);
    } finally {
      this.busy = false;
    }
  }

  /** Walk the sessions tree; attach any recently-written rollout not yet tailed. */
  private async scan(): Promise<void> {
    const files = await this.collectRollouts(join(this.codexHome, "sessions"));
    const cutoff = Date.now() - this.activeMs;
    for (const file of files) {
      if (this.tails.has(file)) continue;
      try {
        const s = await stat(file);
        if (s.mtimeMs < cutoff) continue; // stale until it changes again
        await this.attach(file, s.size);
      } catch (err) {
        this.log(`codex reader: cannot attach ${file}: ${String(err)}`);
      }
    }
  }

  private async collectRollouts(dir: string, depth = 0): Promise<string[]> {
    if (depth > 4) return [];
    let entries;
    try {
      entries = await readdir(dir, { withFileTypes: true });
    } catch {
      return []; // Codex not installed / dir missing — fine
    }
    const out: string[] = [];
    for (const entry of entries) {
      const p = join(dir, entry.name);
      if (entry.isDirectory()) out.push(...(await this.collectRollouts(p, depth + 1)));
      else if (entry.isFile() && ROLLOUT_RE.test(entry.name)) out.push(p);
    }
    return out;
  }

  /**
   * Catch-up on a newly attached file: run every entry through the context so
   * identity/meta are right, but ingest only a compact summary — the
   * session_started plus the latest mapped event — so attaching a long-running
   * session doesn't replay its whole history into the hub.
   */
  private async attach(file: string, size: number): Promise<void> {
    const ctx = createCodexContext(UUID_RE.exec(file)?.[1]?.toLowerCase());
    const state: TailState = { ctx, offset: 0, questionPending: false };

    const buf = await readFile(file);
    const lastNewline = buf.lastIndexOf(0x0a);
    state.offset = lastNewline === -1 ? 0 : lastNewline + 1;

    let started: EventInput | null = null;
    let latest: EventInput | null = null;
    if (lastNewline !== -1) {
      for (const line of buf.subarray(0, lastNewline + 1).toString("utf8").split("\n")) {
        const entry = parseRolloutLine(line);
        if (!entry) continue;
        const mapped = mapCodexEntry(entry, ctx);
        if (!mapped) continue;
        if (mapped.type === "session_started") started = mapped;
        else latest = mapped;
      }
    }
    // Which process this is, for the resource meter. Resolved once per attach
    // (one `lsof`, ~30ms) and folded into the context so every later event
    // carries it; unresolvable is simply no meter.
    const pid = await resolveCodexPid(file);
    if (pid !== null) {
      ctx.meta.pid = String(pid);
      if (started) {
        const detail = { ...(started.detail ?? {}) };
        detail._meta = { ...((detail._meta as Record<string, unknown> | undefined) ?? {}), pid: String(pid) };
        started = { ...started, detail };
      }
    }
    // Identity settles as the file is read, so re-stamp before ingesting.
    if (started) this.sink.ingest({ ...started, session_id: ctx.sessionId ?? started.session_id });
    if (latest) this.sink.ingest({ ...latest, cwd: ctx.cwd ?? latest.cwd });

    this.tails.set(file, state);
    void size;
  }

  private async pollAttached(): Promise<void> {
    const cutoff = Date.now() - this.activeMs;
    for (const [file, state] of this.tails) {
      try {
        const s = await stat(file);
        if (s.size < state.offset) {
          // Truncated/rewritten (never observed, but cheap to survive): start over.
          this.tails.delete(file);
          continue;
        }
        if (s.size > state.offset) {
          await this.readAppended(file, state, s.size);
        } else if (s.mtimeMs < cutoff) {
          this.tails.delete(file); // idle; a later write re-attaches via scan()
        }
      } catch {
        this.tails.delete(file); // deleted or unreadable — silently let go
      }
    }
  }

  /** Read [offset, size), process whole lines, leave a trailing partial for later. */
  private async readAppended(file: string, state: TailState, size: number): Promise<void> {
    const length = size - state.offset;
    const buf = Buffer.alloc(length);
    const fh = await open(file, "r");
    try {
      await fh.read(buf, 0, length, state.offset);
    } finally {
      await fh.close();
    }
    const lastNewline = buf.lastIndexOf(0x0a);
    if (lastNewline === -1) return; // partial line — wait for the rest
    for (const line of buf.subarray(0, lastNewline + 1).toString("utf8").split("\n")) {
      this.processLine(line, state);
    }
    state.offset += lastNewline + 1;
  }

  private processLine(line: string, state: TailState): void {
    const entry = parseRolloutLine(line);
    if (!entry) {
      if (line.trim()) this.log("codex reader: skipped malformed rollout line");
      return;
    }
    const mapped = mapCodexEntry(entry, state.ctx);
    if (!mapped) return;
    this.sink.ingest(mapped);

    // Mirror the Claude route: a question waits in the notch until any
    // subsequent activity shows it was answered (or abandoned).
    const sessionId = state.ctx.sessionId;
    if (!sessionId) return;
    const question = extractCodexQuestion(entry);
    if (question) {
      this.sink.setPendingQuestion(sessionId, question);
      state.questionPending = true;
    } else if (state.questionPending) {
      this.sink.setPendingQuestion(sessionId, null);
      state.questionPending = false;
    }
  }
}
