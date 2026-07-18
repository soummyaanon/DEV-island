import { z } from "zod";

/** Which agent produced an event. v0.1 integrates exactly these two. */
export const AgentKindSchema = z.enum(["claude-code", "codex"]);

export type AgentKind = z.infer<typeof AgentKindSchema>;
