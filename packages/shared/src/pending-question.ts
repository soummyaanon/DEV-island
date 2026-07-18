import { z } from "zod";

/**
 * A multiple-choice question Claude is asking the user (the AskUserQuestion
 * tool). Surfaced in the notch while Claude waits; answering happens in the
 * terminal (jump-to-terminal), since the CLI owns the input.
 */
export const PendingQuestionSchema = z.object({
  id: z.string(),
  /** The question text (first question if the tool asked several). */
  question: z.string(),
  /** Option labels, in order. */
  options: z.array(z.string()),
  created_at: z.string().datetime(),
});

export type PendingQuestion = z.infer<typeof PendingQuestionSchema>;
