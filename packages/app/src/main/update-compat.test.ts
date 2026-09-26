import { describe, expect, it } from "vitest";
import { runsOnThisMac } from "./update-compat";

describe("runsOnThisMac", () => {
  it("offers 1.x releases on any Mac 1.x runs on", () => {
    expect(runsOnThisMac("v1.9.2", "11.7.10")).toBe(true);
  });

  it("offers 2.0 only on macOS 14 and later", () => {
    expect(runsOnThisMac("v2.0.0", "13.6.1")).toBe(false);
    expect(runsOnThisMac("v2.0.0", "12.7")).toBe(false);
    expect(runsOnThisMac("v2.0.0", "14.0")).toBe(true);
    expect(runsOnThisMac("2.1.0", "26.0.1")).toBe(true);
  });

  it("never blocks when the macOS version can't be read", () => {
    expect(runsOnThisMac("v2.0.0", "")).toBe(true);
  });
});
