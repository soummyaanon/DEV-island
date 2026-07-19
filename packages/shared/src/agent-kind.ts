import { z } from "zod";

/** Which agent produced an event. v0.1 integrates exactly these three. */
export const AgentKindSchema = z.enum(["claude-code", "codex", "cursor"]);

export type AgentKind = z.infer<typeof AgentKindSchema>;
