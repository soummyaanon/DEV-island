import { beforeEach, describe, expect, it, vi } from "vitest";

const send = vi.fn((_command: string) => true);
const isAvailable = vi.fn(() => true);

vi.mock("./native-helper", () => ({
  send: (command: string) => send(command),
  isAvailable: () => isAvailable(),
}));

beforeEach(() => {
  vi.resetModules();
  send.mockClear();
  send.mockReturnValue(true);
  isAvailable.mockClear();
  isAvailable.mockReturnValue(true);
  vi.useRealTimers();
});

/** The three primitives NSHapticFeedbackManager actually offers. */
const PRIMITIVES = new Set(["generic", "alignment", "levelChange"]);

describe("rhythm table", () => {
  it("only uses primitives macOS can perform", async () => {
    const { RHYTHMS } = await import("./haptics");
    for (const [pattern, rhythm] of Object.entries(RHYTHMS)) {
      const parts = rhythm.split(",");
      parts.forEach((part, index) => {
        // Alternating pattern / gap, starting with a pattern.
        if (index % 2 === 0) {
          expect(PRIMITIVES, `${pattern} step ${index}`).toContain(part);
        } else {
          expect(Number.isInteger(Number(part)), `${pattern} gap ${part}`).toBe(true);
        }
      });
    }
  });

  it("gives every pattern a rhythm and a priority", async () => {
    const { RHYTHMS, PRIORITY } = await import("./haptics");
    expect(Object.keys(RHYTHMS).sort()).toEqual(Object.keys(PRIORITY).sort());
  });

  it("keeps rumble slower than attention — the only thing distinguishing them", async () => {
    const { RHYTHMS } = await import("./haptics");
    const gap = (rhythm: string) => Number(rhythm.split(",")[1]);
    expect(gap(RHYTHMS.rumble)).toBeGreaterThan(gap(RHYTHMS.attention));
  });
});

describe("pickWinner", () => {
  it("returns null for an empty batch", async () => {
    const { pickWinner } = await import("./haptics");
    expect(pickWinner([])).toBeNull();
  });

  it("lets a failure beat everything else in the batch", async () => {
    const { pickWinner } = await import("./haptics");
    expect(pickWinner(["tick", "success", "failure", "attention"])).toBe("failure");
  });

  it("prefers attention over success — needing you outranks being done", async () => {
    const { pickWinner } = await import("./haptics");
    expect(pickWinner(["success", "attention"])).toBe("attention");
  });

  it("never lets ambient weather outrank a real event", async () => {
    const { pickWinner } = await import("./haptics");
    expect(pickWinner(["whisper", "tick"])).toBe("tick");
    expect(pickWinner(["rumble", "failure"])).toBe("failure");
  });
});

describe("canFire", () => {
  it("allows the first pulse of a run", async () => {
    const { canFire } = await import("./haptics");
    expect(canFire(0, Number.NEGATIVE_INFINITY)).toBe(true);
  });

  it("suppresses a second pulse inside the window and allows it after", async () => {
    const { canFire, MIN_GAP_MS } = await import("./haptics");
    expect(canFire(1000 + MIN_GAP_MS - 1, 1000)).toBe(false);
    expect(canFire(1000 + MIN_GAP_MS, 1000)).toBe(true);
  });
});

describe("haptic batching", () => {
  it("collapses a whole snapshot's transitions into one pulse", async () => {
    vi.useFakeTimers();
    const { haptic, RHYTHMS } = await import("./haptics");

    // Ten sessions finishing at once, plus one failure among them.
    for (let i = 0; i < 10; i++) haptic("success");
    haptic("failure");
    await vi.advanceTimersByTimeAsync(1);

    expect(send).toHaveBeenCalledTimes(1);
    expect(send).toHaveBeenCalledWith(`haptic ${RHYTHMS.failure}`);
  });

  it("drops a second batch inside the rate-limit window", async () => {
    vi.useFakeTimers();
    const { haptic } = await import("./haptics");

    haptic("tick");
    await vi.advanceTimersByTimeAsync(1);
    expect(send).toHaveBeenCalledTimes(1);

    haptic("tick");
    await vi.advanceTimersByTimeAsync(1);
    expect(send).toHaveBeenCalledTimes(1);
  });

  it("fires again once the window has passed", async () => {
    vi.useFakeTimers();
    const { haptic, MIN_GAP_MS } = await import("./haptics");

    haptic("tick");
    await vi.advanceTimersByTimeAsync(1);
    await vi.advanceTimersByTimeAsync(MIN_GAP_MS);
    haptic("tick");
    await vi.advanceTimersByTimeAsync(1);

    expect(send).toHaveBeenCalledTimes(2);
  });

  it("sends nothing while disabled", async () => {
    vi.useFakeTimers();
    const { haptic, setHapticsEnabled } = await import("./haptics");

    setHapticsEnabled(false);
    haptic("failure");
    await vi.advanceTimersByTimeAsync(1);

    expect(send).not.toHaveBeenCalled();
  });

  it("does not consume the rate-limit window when the helper is missing", async () => {
    vi.useFakeTimers();
    send.mockReturnValue(false); // helper absent: write never lands
    const { haptic } = await import("./haptics");

    haptic("tick");
    await vi.advanceTimersByTimeAsync(1);
    haptic("tick");
    await vi.advanceTimersByTimeAsync(1);

    // Both attempts reach the helper; a failed send must not look like success
    // and lock out the next real pulse.
    expect(send).toHaveBeenCalledTimes(2);
  });
});
