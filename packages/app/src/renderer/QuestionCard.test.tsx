import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it } from "vitest";
import type { SessionSnapshot } from "@agent-island/shared";
import { QuestionCard } from "./QuestionCard";

function sessionWith(questions: Array<{ question: string; options: string[] }>): SessionSnapshot {
  return {
    agent: "claude-code",
    cwd: "/Users/me/project",
    pending_question: { id: "question-1", questions, created_at: "2026-07-19T10:00:00.000Z" },
  } as SessionSnapshot;
}

describe("QuestionCard", () => {
  it("renders a single question with ⌘n hints and each option as a button", () => {
    const html = renderToStaticMarkup(
      <QuestionCard
        session={sessionWith([
          {
            question: "Deploy where?",
            options: ["Production — Deploy the current release", "Staging — Run a final smoke test"],
          },
        ])}
        onJump={() => {}}
        onAnswer={() => {}}
      />,
    );

    expect(html).toContain("Deploy where?");
    expect(html).toContain("Production — Deploy the current release");
    expect(html).toContain("Staging — Run a final smoke test");
    expect(html.match(/<button/g)).toHaveLength(2);
    expect(html).toContain("⌘1");
  });

  it("renders every sub-question of a multi-question ask, without ⌘n hints", () => {
    const html = renderToStaticMarkup(
      <QuestionCard
        session={sessionWith([
          { question: "Fail sound?", options: ["Keep", "Drop"] },
          { question: "Settings UI?", options: ["Fine", "Broken"] },
        ])}
        onJump={() => {}}
        onAnswer={() => {}}
      />,
    );

    expect(html).toContain("Fail sound?");
    expect(html).toContain("Settings UI?");
    expect(html.match(/<button/g)).toHaveLength(4);
    expect(html).not.toContain("⌘1");
    expect(html).toContain("pick one per question");
  });
});
