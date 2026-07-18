import { z } from "zod";

/**
 * A tool call awaiting the user's decision in the notch. Set on a session while
 * the daemon holds the agent's permission hook open; cleared once resolved.
 */
export const PendingApprovalSchema = z.object({
  id: z.string(),
  tool_name: z.string(),
  tool_input: z.record(z.unknown()),
  /** Optional plan/markdown text (e.g. from ExitPlanMode) to render for review. */
  plan: z.string().optional(),
  created_at: z.string().datetime(),
});

export type PendingApproval = z.infer<typeof PendingApprovalSchema>;

export const ApprovalDecisionSchema = z.enum(["allow", "deny"]);
export type ApprovalDecision = z.infer<typeof ApprovalDecisionSchema>;
