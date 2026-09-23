import { describe, expect, it } from "vitest";
import { editCommandFor } from "./edit-shortcuts";

const key = (k: string, mods: Partial<{ meta: boolean; control: boolean; alt: boolean; shift: boolean }> = {}) => ({
  type: "keyDown" as const,
  key: k,
  meta: true,
  control: false,
  alt: false,
  shift: false,
  ...mods,
});

describe("editCommandFor", () => {
  it("maps the Command edit shortcuts", () => {
    expect(editCommandFor(key("v"))).toBe("paste");
    expect(editCommandFor(key("V", { shift: true }))).toBe("pasteAndMatchStyle");
    expect(editCommandFor(key("c"))).toBe("copy");
    expect(editCommandFor(key("x"))).toBe("cut");
    expect(editCommandFor(key("a"))).toBe("selectAll");
    expect(editCommandFor(key("z"))).toBe("undo");
    expect(editCommandFor(key("z", { shift: true }))).toBe("redo");
  });

  it("leaves everything else alone — Ctrl+V, ⌘Y/⌘N approvals, ⌘1–9 answers, key-ups", () => {
    expect(editCommandFor(key("v", { meta: false, control: true }))).toBeNull();
    expect(editCommandFor(key("y"))).toBeNull();
    expect(editCommandFor(key("n"))).toBeNull();
    expect(editCommandFor(key("1"))).toBeNull();
    expect(editCommandFor(key("v", { alt: true }))).toBeNull();
    expect(editCommandFor({ ...key("v"), type: "keyUp" as never })).toBeNull();
  });
});
