import { describe, expect, it } from "vitest";
import { parseVoiceLine } from "./voice";

const b64 = (s: string) => Buffer.from(s, "utf8").toString("base64");

describe("parseVoiceLine", () => {
  it("reads the listening lifecycle", () => {
    expect(parseVoiceLine("voice listening v1")).toEqual({ id: "v1", type: "listening" });
    expect(parseVoiceLine(`voice partial v1 ${b64("open saf")}`)).toEqual({ id: "v1", type: "partial", text: "open saf" });
    expect(parseVoiceLine(`voice final v1 ${b64("Open Safari.")}`)).toEqual({ id: "v1", type: "final", text: "Open Safari." });
    expect(parseVoiceLine("voice error v1 mic-denied")).toEqual({ id: "v1", type: "error", reason: "mic-denied" });
    expect(parseVoiceLine("speak done")).toEqual({ id: "", type: "spoken" });
  });

  it("clamps levels and ignores other lines", () => {
    expect(parseVoiceLine("voice level v1 0.42")).toEqual({ id: "v1", type: "level", level: 0.42 });
    expect(parseVoiceLine("voice level v1 7")).toEqual({ id: "v1", type: "level", level: 1 });
    expect(parseVoiceLine("voice level v1 nope")).toBeNull();
    expect(parseVoiceLine("ai done q1")).toBeNull();
  });
});
