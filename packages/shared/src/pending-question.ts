import { z } from "zod";

/**
 * A multiple-choice question an agent is asking the user (Claude's
 * AskUserQuestion tool, Codex's request_user_input). Surfaced in the notch
 * while the agent waits. Claude questions are answered directly from the notch
 * (the daemon holds the hook open and replies with the choice); Codex answers
 * fall back to jump-to-terminal + keystrokes.
 */
export const PendingSubQuestionSchema = z.object({
  /** The question text. */
  question: z.string(),
  /** Display labels for its options, in order (answers are sent as indices). */
  options: z.array(z.string()),
  /** Several options may be picked (Claude's `multiSelect`). */
  multiSelect: z.boolean().optional(),
});

export const PendingQuestionSchema = z.object({
  id: z.string(),
  /** Every question in the ask — the notch collects one choice per entry. */
  questions: z.array(PendingSubQuestionSchema).min(1),
  created_at: z.string().datetime(),
});

export type PendingSubQuestion = z.infer<typeof PendingSubQuestionSchema>;
export type PendingQuestion = z.infer<typeof PendingQuestionSchema>;
