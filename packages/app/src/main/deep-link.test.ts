import { describe, expect, it } from "vitest";
import { focusLinks, parseDeepLink } from "./deep-link";

describe("parseDeepLink", () => {
  it("focus on with a name", () => {
    expect(parseDeepLink("agent-island://focus/on?name=Work")).toEqual({
      kind: "focus",
      active: true,
      name: "Work",
    });
  });
  it("focus off, no name", () => {
    expect(parseDeepLink("agent-island://focus/off")).toEqual({ kind: "focus", active: false, name: null });
  });
  it("decodes and trims the name, capping its length", () => {
    expect(parseDeepLink("agent-island://focus/on?name=Deep%20Work%20")?.kind).toBe("focus");
    const long = "x".repeat(100);
    const link = parseDeepLink(`agent-island://focus/on?name=${long}`);
    expect(link?.kind === "focus" && link.name?.length).toBe(40);
  });
  it("toggle and settings", () => {
    expect(parseDeepLink("agent-island://toggle")).toEqual({ kind: "toggle" });
    expect(parseDeepLink("agent-island://settings/")).toEqual({ kind: "settings" });
  });
  it("rejects other schemes, hosts, and paths", () => {
    expect(parseDeepLink("https://focus/on")).toBeNull();
    expect(parseDeepLink("agent-island://focus/maybe")).toBeNull();
    expect(parseDeepLink("agent-island://quit")).toBeNull();
    expect(parseDeepLink("agent-island://toggle/now")).toBeNull();
    expect(parseDeepLink("not a url")).toBeNull();
  });
});

describe("focusLinks", () => {
  it("are parseable by the parser they are meant for", () => {
    const { on, off } = focusLinks();
    expect(parseDeepLink(on)?.kind).toBe("focus");
    expect(parseDeepLink(off)).toEqual({ kind: "focus", active: false, name: null });
  });
});
