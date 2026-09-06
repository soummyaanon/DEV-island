import { describe, expect, it } from "vitest";
import { GLASS_OVERLAP, glassFrame, parseGlassCaps, parseWindowId } from "./glass";

const win = { x: 350, y: 0, width: 820, height: 560 };

describe("glassFrame", () => {
  it("offsets the panel rect by the window origin and tucks it under the band", () => {
    const frame = glassFrame(win, { x: 210, y: 33, width: 400, height: 180 });
    expect(frame).toEqual({ x: 560, y: 33 - GLASS_OVERLAP, width: 400, height: 180 + GLASS_OVERLAP });
  });

  it("is null while collapsed (no panel, or a hairline)", () => {
    expect(glassFrame(win, null)).toBeNull();
    expect(glassFrame(win, { x: 0, y: 33, width: 300, height: 0 })).toBeNull();
    expect(glassFrame(win, { x: 0, y: 33, width: 300, height: 2 })).toBeNull();
  });

  it("rounds to whole pixels", () => {
    const frame = glassFrame(win, { x: 10.4, y: 33.6, width: 300.5, height: 100.2 });
    expect(frame).toEqual({ x: 360, y: 28, width: 301, height: 106 });
  });
});

describe("parseGlassCaps", () => {
  it("reads the three tiers and ignores everything else", () => {
    expect(parseGlassCaps("glass native")).toBe("native");
    expect(parseGlassCaps("glass vibrancy\n")).toBe("vibrancy");
    expect(parseGlassCaps("glass none")).toBe("none");
    expect(parseGlassCaps("ok")).toBeNull();
    expect(parseGlassCaps("glass shiny")).toBeNull();
  });
});

describe("parseWindowId", () => {
  it("extracts the CGWindowID from Electron's media source id", () => {
    expect(parseWindowId("window:4821:0")).toBe(4821);
  });
  it("is 0 for anything unexpected", () => {
    expect(parseWindowId("screen:0:0")).toBe(0);
    expect(parseWindowId("")).toBe(0);
    expect(parseWindowId("window:0:0")).toBe(0);
  });
});
