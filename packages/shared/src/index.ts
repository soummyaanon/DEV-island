// @agent-island/shared — canonical event schemas and wire types.
// Single source of truth: the daemon validates against these at its edges and
// the app trusts the decoded types. Keep this the only place the contract lives.

export * from "./agent-kind";
export * from "./session-state";
export * from "./agent-event";
export * from "./pending-approval";
export * from "./session-snapshot";
export * from "./wire-protocol";
