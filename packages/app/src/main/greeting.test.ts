import { describe, expect, it } from "vitest";
import { factsText, fallbackLine, greetingTitle, parseGreetLine, partOfDay, tidyLine } from "./greeting";

const at = (h: number, day = 3) => new Date(2026, 8, 20 + day, h, 5); // Sep 23 2026 = Wednesday when day=3

describe("greeting", () => {
  it("names the part of the day", () => {
    expect(partOfDay(7)).toBe("morning");
    expect(partOfDay(13)).toBe("afternoon");
    expect(partOfDay(19)).toBe("evening");
    expect(partOfDay(2)).toBe("night");
  });

  it("titles launch and welcome-back", () => {
    expect(greetingTitle("Sam", at(8), "launch")).toBe("Good morning, Sam");
    expect(greetingTitle("", at(23), "launch")).toBe("Hey there");
    expect(greetingTitle("Sam", at(15), "welcome-back")).toBe("Welcome back, Sam");
  });

  it("hands the model short fact lines, skipping what's unknown", () => {
    const text = factsText({ name: "Sam", date: at(9), occasion: "launch", weather: null, battery: { percent: 80, charging: true } });
    expect(text).toContain("Name: Sam");
    expect(text).toContain("Battery: 80%, charging");
    expect(text).not.toContain("Weather");
  });

  it("falls back to a local line; low battery first", () => {
    const f = { name: "Sam", date: at(14), occasion: "launch" as const, battery: { percent: 9, charging: false } };
    expect(fallbackLine(f, 0)).toContain("9%");
    expect(fallbackLine(f, 0.99).length).toBeGreaterThan(0);
  });

  it("parses the sidecar's greet replies", () => {
    const b64 = Buffer.from("Morning! Coffee first?", "utf8").toString("base64");
    expect(parseGreetLine(`ai greet g1 ${b64}`)).toEqual({ id: "g1", text: "Morning! Coffee first?" });
    expect(parseGreetLine("ai greet-error g2 model-failed")).toEqual({ id: "g2", text: null });
    expect(parseGreetLine("ai delta g1 abc")).toBeNull();
  });

  it("keeps the line to one tidy sentence", () => {
    expect(tidyLine(' "Hello\n there" ')).toBe("Hello there");
    expect(tidyLine("word ".repeat(60)).length).toBeLessThanOrEqual(141);
  });
});

describe("dropSalutation", () => {
  it("drops the model's own hello and the name the title already shows", async () => {
    const { dropSalutation } = await import("./greeting");
    expect(dropSalutation("Good night, Soumyaranjan. Ready for your Saturday adventure?", "Soumyaranjan")).toBe(
      "Ready for your Saturday adventure?",
    );
    expect(dropSalutation("Hey soumyaranjan, coffee first?", "Soumyaranjan")).toBe("Coffee first?");
    expect(dropSalutation("Ready when you are.", "Sam")).toBe("Ready when you are.");
    expect(dropSalutation("Hello!", "Sam")).toBe("Hello!");
    expect(dropSalutation("Hey there, Sam! Big day?", "Sam")).toBe("Big day?");
  });
});
