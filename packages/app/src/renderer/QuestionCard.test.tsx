import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it } from "vitest";
import type { SessionSnapshot } from "@agent-island/shared";
import { QuestionCard } from "./QuestionCard";

describe("QuestionCard", () => {
  it("renders the complete question and each option as a button", () => {
    const session = {
      agent: "claude-code",
      cwd: "/Users/me/project",
      pending_question: {
        id: "question-1",
        question: "Deploy where?",
        options: [
          "Production — Deploy the current release",
          "Staging — Run a final smoke test",
        ],
      },
    } as SessionSnapshot;

    const html = renderToStaticMarkup(
      <QuestionCard session={session} onJump={() => {}} onAnswer={() => {}} />,
    );

    expect(html).toContain("Deploy where?");
    expect(html).toContain("Production — Deploy the current release");
    expect(html).toContain("Staging — Run a final smoke test");
    expect(html.match(/<button/g)).toHaveLength(2);
  });
});
