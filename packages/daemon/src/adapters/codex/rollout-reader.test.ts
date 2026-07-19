import { mkdtemp, mkdir, rm, utimes, writeFile, appendFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import type { EventInput, PendingQuestion } from "@agent-island/shared";
import { CodexRolloutReader } from "./rollout-reader";

const UUID = "019f790e-889e-7370-a86b-b7e9b65e13e8";

function line(type: string, payload: Record<string, unknown>): string {
  return `${JSON.stringify({ timestamp: "2026-07-19T06:00:00.000Z", type, payload })}\n`;
}

const SESSION_META = line("session_meta", { session_id: UUID, cwd: "/Users/me/proj" });
const TASK_STARTED = line("event_msg", { type: "task_started" });
const TASK_COMPLETE = line("event_msg", { type: "task_complete", last_agent_message: "did it" });
const EXEC_CALL = line("response_item", {
  type: "function_call",
  name: "exec_command",
  arguments: '{"cmd":"ls -la"}',
});
const ASK = line("response_item", {
  type: "function_call",
  name: "request_user_input",
  arguments: '{"questions":[{"question":"Which?","options":[{"label":"A"}]}]}',
});

function makeSink() {
  const events: EventInput[] = [];
  const questions: Array<{ sessionId: string; question: PendingQuestion | null }> = [];
  return {
    events,
    questions,
    sink: {
      ingest: (input: EventInput) => {
        events.push(input);
      },
      setPendingQuestion: (sessionId: string, question: PendingQuestion | null) => {
        questions.push({ sessionId, question });
      },
    },
  };
}

async function until(cond: () => boolean, ms = 4000): Promise<void> {
  const start = Date.now();
  while (!cond()) {
    if (Date.now() - start > ms) throw new Error("timed out waiting for condition");
    await new Promise((r) => setTimeout(r, 5));
  }
}

describe("CodexRolloutReader", () => {
  let home: string;
  let dayDir: string;
  let reader: CodexRolloutReader | null = null;

  beforeEach(async () => {
    home = await mkdtemp(join(tmpdir(), "codex-home-"));
    dayDir = join(home, "sessions", "2026", "07", "19");
    await mkdir(dayDir, { recursive: true });
  });

  afterEach(async () => {
    reader?.stop();
    reader = null;
    await rm(home, { recursive: true, force: true });
  });

  function startReader(sink: ReturnType<typeof makeSink>["sink"], activeMs = 60_000) {
    reader = new CodexRolloutReader(home, sink, { pollMs: 15, scanMs: 25, activeMs });
    return reader.start();
  }

  function rolloutPath(uuid = UUID): string {
    return join(dayDir, `rollout-2026-07-19T06-00-00-${uuid}.jsonl`);
  }

  it("catch-up compacts an existing file to session_started + latest state", async () => {
    await writeFile(rolloutPath(), SESSION_META + TASK_STARTED + EXEC_CALL + TASK_COMPLETE);
    const { events, sink } = makeSink();
    await startReader(sink);
    await until(() => events.length >= 2);

    expect(events).toHaveLength(2);
    expect(events[0]).toMatchObject({ type: "session_started", session_id: UUID, cwd: "/Users/me/proj" });
    expect(events[1]).toMatchObject({ type: "session_ended", title: "did it" });
  });

  it("streams appended lines live", async () => {
    await writeFile(rolloutPath(), SESSION_META);
    const { events, sink } = makeSink();
    await startReader(sink);
    await until(() => events.length >= 1);

    await appendFile(rolloutPath(), TASK_STARTED + EXEC_CALL);
    await until(() => events.length >= 3);
    expect(events[1]).toMatchObject({ type: "task_progress", title: "working…" });
    expect(events[2]).toMatchObject({ type: "tool_use", title: "Running ls -la" });
  });

  it("buffers a partial line until its newline arrives", async () => {
    await writeFile(rolloutPath(), SESSION_META);
    const { events, sink } = makeSink();
    await startReader(sink);
    await until(() => events.length >= 1);

    const [head, tail] = [TASK_STARTED.slice(0, 25), TASK_STARTED.slice(25)];
    await appendFile(rolloutPath(), head);
    await new Promise((r) => setTimeout(r, 80));
    expect(events).toHaveLength(1); // half a line is not an event

    await appendFile(rolloutPath(), tail);
    await until(() => events.length >= 2);
    expect(events[1]).toMatchObject({ type: "task_progress", title: "working…" });
  });

  it("skips malformed lines without dying", async () => {
    await writeFile(rolloutPath(), SESSION_META);
    const { events, sink } = makeSink();
    await startReader(sink);
    await until(() => events.length >= 1);

    await appendFile(rolloutPath(), "{not json at all\n" + TASK_STARTED);
    await until(() => events.length >= 2);
    expect(events[1]).toMatchObject({ type: "task_progress" });
  });

  it("picks up files created after start", async () => {
    const { events, sink } = makeSink();
    await startReader(sink);

    const other = "029f790e-889e-7370-a86b-b7e9b65e13e9";
    await writeFile(rolloutPath(other), SESSION_META.replace(UUID, other));
    await until(() => events.length >= 1);
    expect(events[0]).toMatchObject({ type: "session_started", session_id: other });
  });

  it("ignores files that were last written before the recency window", async () => {
    await writeFile(rolloutPath(), SESSION_META + TASK_COMPLETE);
    const old = (Date.now() - 3_600_000) / 1000;
    await utimes(rolloutPath(), old, old);

    const { events, sink } = makeSink();
    await startReader(sink, 60_000);
    await new Promise((r) => setTimeout(r, 120));
    expect(events).toHaveLength(0);
  });

  it("sets the pending question on request_user_input and clears it on the next event", async () => {
    await writeFile(rolloutPath(), SESSION_META);
    const { events, questions, sink } = makeSink();
    await startReader(sink);
    await until(() => events.length >= 1);

    await appendFile(rolloutPath(), ASK);
    await until(() => questions.length >= 1);
    expect(questions[0].sessionId).toBe(UUID);
    expect(questions[0].question).toMatchObject({ question: "Which?", options: ["A"] });

    await appendFile(rolloutPath(), TASK_STARTED);
    await until(() => questions.length >= 2);
    expect(questions[1]).toMatchObject({ sessionId: UUID, question: null });
  });

  it("falls back to the filename uuid when a file has no session_meta yet", async () => {
    await writeFile(rolloutPath(), TASK_STARTED);
    const { events, sink } = makeSink();
    await startReader(sink);
    await until(() => events.length >= 1);
    expect(events[0]).toMatchObject({ session_id: UUID, cwd: "(unknown)" });
  });
});
