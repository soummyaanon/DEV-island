import { describe, expect, it } from "vitest";
import { parseSwipeScrollDirection } from "./scroll-direction";

describe("parseSwipeScrollDirection", () => {
  it("1 is natural scrolling", () => {
    expect(parseSwipeScrollDirection("1\n")).toBe(true);
  });
  it("0 is classic scrolling", () => {
    expect(parseSwipeScrollDirection("0\n")).toBe(false);
  });
  it("anything else — unset key, error text, empty — assumes the macOS default (natural)", () => {
    expect(parseSwipeScrollDirection("")).toBe(true);
    expect(parseSwipeScrollDirection(undefined)).toBe(true);
    expect(parseSwipeScrollDirection("The domain/default pair does not exist")).toBe(true);
  });
});
