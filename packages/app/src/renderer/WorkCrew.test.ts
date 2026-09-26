import { describe, expect, it } from "vitest";
import { MAX_WORK_BOTS, workCrew } from "./WorkCrew";

describe("workCrew", () => {
  it("draws one bot per working session", () => {
    expect(workCrew(["a", "b"])).toEqual({ shown: ["a", "b"], more: 0 });
  });

  it("folds everything past the cap into +n", () => {
    const { shown, more } = workCrew(["a", "b", "c", "d", "e"]);
    expect(shown).toHaveLength(MAX_WORK_BOTS);
    expect(more).toBe(2);
  });
});
