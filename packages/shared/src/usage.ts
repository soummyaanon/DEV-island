import { z } from "zod";
import { AgentKindSchema } from "./agent-kind";

/** One rate-limit window (e.g. the 5-hour or weekly cap). */
export const UsageWindowSchema = z.object({
  label: z.string(),
  /** 0-100, amount USED (remaining = 100 - used_percent). */
  used_percent: z.number(),
  /** Unix seconds when this window resets, or null if unknown. */
  resets_at: z.number().nullable(),
});

/** Account-level quota for one agent, read from local data (no network). */
export const AgentUsageSchema = z.object({
  agent: AgentKindSchema,
  plan: z.string().nullable(),
  windows: z.array(UsageWindowSchema),
  /** Credit balance as reported (string to preserve exactness), or null. */
  credits: z.string().nullable(),
  updated_at: z.string().datetime(),
});

export type UsageWindow = z.infer<typeof UsageWindowSchema>;
export type AgentUsage = z.infer<typeof AgentUsageSchema>;
