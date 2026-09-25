import { describe, expect, it } from "vitest";
import { askCommand, isWebUrl, parseAssistantCaps, parseAssistantLine } from "./assistant";

const b64 = (s: string) => Buffer.from(s, "utf8").toString("base64");

describe("parseAssistantCaps", () => {
  it("reads full and basic mode, with the reason the model can't answer", () => {
    expect(parseAssistantCaps("ai available")).toEqual({ support: "available", reason: "" });
    expect(parseAssistantCaps("ai basic not-enabled")).toEqual({ support: "basic", reason: "not-enabled" });
    expect(parseAssistantCaps("ai basic os\n")).toEqual({ support: "basic", reason: "os" });
    expect(parseAssistantCaps("glass native")).toBeNull();
    expect(parseAssistantCaps("ai done q1")).toBeNull();
  });
});

describe("parseAssistantLine", () => {
  it("decodes cumulative deltas, keeping spaces and newlines", () => {
    expect(parseAssistantLine(`ai delta q1 ${b64("two lines\nhere")}`)).toEqual({
      id: "q1",
      type: "delta",
      text: "two lines\nhere",
    });
  });

  it("reads done and error", () => {
    expect(parseAssistantLine("ai done q1")).toEqual({ id: "q1", type: "done" });
    expect(parseAssistantLine("ai error q1 guardrail")).toEqual({
      id: "q1",
      type: "error",
      reason: "guardrail",
    });
  });

  it("reads open and draft actions and drops malformed ones", () => {
    expect(parseAssistantLine(`ai action q1 ${b64('{"kind":"open","project":"web"}')}`)).toEqual({
      id: "q1",
      type: "action",
      action: { kind: "open", project: "web" },
    });
    expect(
      parseAssistantLine(`ai action q2 ${b64('{"kind":"draft","project":"api","message":"run tests"}')}`),
    ).toEqual({ id: "q2", type: "action", action: { kind: "draft", project: "api", message: "run tests" } });
    expect(parseAssistantLine(`ai action q1 ${b64("not json")}`)).toBeNull();
    expect(parseAssistantLine(`ai action q1 ${b64('{"kind":"rm -rf"}')}`)).toBeNull();
  });
});

describe("agentic lines", () => {
  it("reads tool steps", () => {
    expect(parseAssistantLine(`ai tool q1 openApp ${b64("Opening Safari")}`)).toEqual({
      id: "q1",
      type: "tool",
      name: "openApp",
      step: "Opening Safari",
    });
  });

  it("reads timers and shortcut proposals, rejecting nonsense", () => {
    expect(parseAssistantLine(`ai action q1 ${b64('{"kind":"timer","minutes":"10","label":"tea"}')}`)).toEqual({
      id: "q1",
      type: "action",
      action: { kind: "timer", minutes: 10, label: "tea" },
    });
    expect(parseAssistantLine(`ai action q1 ${b64('{"kind":"timer","minutes":"9999"}')}`)).toBeNull();
    expect(parseAssistantLine(`ai action q1 ${b64('{"kind":"shortcut","name":"Focus On"}')}`)).toEqual({
      id: "q1",
      type: "action",
      action: { kind: "shortcut", name: "Focus On" },
    });
    expect(parseAssistantLine(`ai action q1 ${b64('{"kind":"shortcut","name":"  "}')}`)).toBeNull();
  });
});

describe("askCommand", () => {
  it("is one line whatever the prompt contains, and sanitises the id", () => {
    const cmd = askCommand("q 1\n", "hi there\nfriend", "- web: working");
    expect(cmd).not.toContain("\n");
    const [, , id, payload] = cmd.split(" ");
    expect(id).toBe("q1");
    expect(JSON.parse(Buffer.from(payload, "base64").toString("utf8"))).toEqual({
      prompt: "hi there\nfriend",
      context: "- web: working",
    });
  });
});

describe("web search sources", () => {
  const enc = (o: unknown) => Buffer.from(JSON.stringify(o), "utf8").toString("base64");
  it("parses cited sources and drops non-web links", () => {
    const line = `ai action q1 ${enc({ kind: "sources", urls: "https://a.com/x\njavascript:alert(1)\nhttp://b.org", titles: "A\nBad\nB" })}`;
    expect(parseAssistantLine(line)).toEqual({
      id: "q1",
      type: "action",
      action: { kind: "sources", sources: [{ url: "https://a.com/x", title: "A" }, { url: "http://b.org", title: "B" }] },
    });
  });
  it("only treats http(s) as web URLs", () => {
    expect(isWebUrl("https://x.dev")).toBe(true);
    expect(isWebUrl("file:///etc/passwd")).toBe(false);
    expect(isWebUrl("not a url")).toBe(false);
  });
});
