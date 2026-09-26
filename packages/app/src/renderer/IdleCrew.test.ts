import { describe, expect, it } from "vitest";
import { gamePose, ROUND_S } from "./IdleCrew";

describe("gamePose", () => {
  it("starts with everyone seated and the seeker's eyes open", () => {
    expect(gamePose(0)).toEqual({ counting: false, notch: "seat", duck: "seat" });
  });

  it("hides both while the seeker counts", () => {
    expect(gamePose(6)).toEqual({ counting: true, notch: "hidden", duck: "hidden" });
  });

  it("brings the hiders home one at a time: a peek, then back to the seat", () => {
    expect(gamePose(11).duck).toBe("peek");
    expect(gamePose(11).notch).toBe("hidden");
    expect(gamePose(13.5)).toEqual({ counting: false, notch: "peek", duck: "seat" });
    expect(gamePose(15)).toEqual({ counting: false, notch: "seat", duck: "seat" });
  });

  it("repeats every round", () => {
    expect(gamePose(ROUND_S + 6)).toEqual(gamePose(6));
  });
});
