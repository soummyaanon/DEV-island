import { describe, expect, it } from "vitest";
import { pickPid } from "./pid";

describe("pickPid", () => {
  it("prefers whoever holds the rollout file open", () => {
    expect(pickPid("4242\n", "1\n2\n")).toBe(4242);
  });
  it("falls back to a lone codex process", () => {
    expect(pickPid("", "777\n")).toBe(777);
  });
  it("refuses to guess between several codex processes", () => {
    expect(pickPid("", "777\n778\n")).toBeNull();
  });
  it("ignores junk", () => {
    expect(pickPid("lsof: WARNING\n", "not-a-pid")).toBeNull();
  });
});
