import { describe, expect, it } from "vitest";
import { islandOutline, islandSilhouette } from "./IslandGlow";

describe("islandOutline", () => {
  it("starts and ends on the bezel through the two ears, never drawing the top edge", () => {
    const d = islandOutline(300, 120);
    expect(d.startsWith("M 0 0 A 10 10 0 0 1 10 10")).toBe(true);
    expect(d.endsWith("A 10 10 0 0 1 320 0")).toBe(true);
    expect(d).not.toMatch(/L \d+ 0\b/);
  });

  it("rounds the bottom corners, clamped for a short island", () => {
    expect(islandOutline(300, 120)).toContain("A 16 16 0 0 0 26 120");
    expect(islandOutline(300, 20)).toContain("A 10 10 0 0 0 20 20");
  });

  it("closes along the bezel for the clip silhouette", () => {
    expect(islandSilhouette(300, 120).endsWith(" Z")).toBe(true);
  });
});
