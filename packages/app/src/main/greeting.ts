import { execFile } from "node:child_process";
import { userInfo } from "node:os";
import { onLine, send } from "./native-helper";
import { assistantSupport, onAssistantSupport } from "./assistant";

/**
 * The hello the island says when it wakes up — at launch, and when you come
 * back to the Mac after a while. Apple's on-device model writes the line from
 * a few plain facts (name, time of day, weather, battery); without it, or if
 * it's slow, a local line stands in. Nothing leaves the Mac.
 */

export interface Greeting {
  /** "Good evening, Sam" */
  title: string;
  /** One playful line. */
  line: string;
  /** The model wrote `line` (vs. the local fallback). */
  ai: boolean;
}

export interface GreetingFacts {
  name: string;
  date: Date;
  weather?: string | null;
  battery?: { percent: number; charging: boolean } | null;
  /** "launch" or "welcome-back". */
  occasion: "launch" | "welcome-back";
}

export function partOfDay(hour: number): "morning" | "afternoon" | "evening" | "night" {
  if (hour >= 5 && hour < 12) return "morning";
  if (hour >= 12 && hour < 17) return "afternoon";
  if (hour >= 17 && hour < 22) return "evening";
  return "night";
}

export function greetingTitle(name: string, date: Date, occasion: GreetingFacts["occasion"]): string {
  const who = name ? `, ${name}` : "";
  if (occasion === "welcome-back") return `Welcome back${who}`;
  const part = partOfDay(date.getHours());
  return part === "night" ? `Hey there${who}` : `Good ${part}${who}`;
}

const WEEKDAYS = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"];

/** The facts as the model sees them — short lines, nothing it could parrot badly. */
export function factsText(f: GreetingFacts): string {
  const lines = [
    f.name ? `Name: ${f.name}` : null,
    `Time of day: ${partOfDay(f.date.getHours())} (${f.date.getHours()}:${String(f.date.getMinutes()).padStart(2, "0")})`,
    `Weekday: ${WEEKDAYS[f.date.getDay()]}`,
    f.occasion === "welcome-back" ? "Occasion: the user just came back to the Mac" : "Occasion: the Mac just started",
    f.weather ? `Weather: ${f.weather}` : null,
    f.battery ? `Battery: ${f.battery.percent}%${f.battery.charging ? ", charging" : ""}` : null,
  ];
  return lines.filter(Boolean).join("\n");
}

/** A local line for when the model can't write one. Deterministic per call site via `pick`. */
export function fallbackLine(f: GreetingFacts, pick: number = Math.random()): string {
  const part = partOfDay(f.date.getHours());
  const day = WEEKDAYS[f.date.getDay()];
  const lines: string[] = [];
  if (f.battery && f.battery.percent <= 20 && !f.battery.charging) {
    lines.push(`Battery's at ${f.battery.percent}%. Maybe find a charger before we build anything big?`);
  }
  if (f.weather) lines.push(`${f.weather} outside. Perfect weather for shipping something.`);
  if (part === "morning") lines.push("Fresh coffee, fresh commits. What are we building today?");
  if (part === "night") lines.push("Burning the midnight oil? I'm awake too.");
  if (day === "Friday") lines.push("It's Friday. Small, safe changes only, deal?");
  if (day === "Monday") lines.push("New week, clean slate. Let's make it a good one.");
  lines.push(
    "I'm up! Point an agent at something and I'll keep an eye on it.",
    "Ready when you are. Hover over me to ask anything.",
    `Happy ${day}. Your agents and I are standing by.`,
  );
  return lines[Math.floor(pick * lines.length) % lines.length];
}

/** The user's first name: macOS full name when set, else the login name. */
let nameCache: string | null = null;
export function firstName(): Promise<string> {
  if (nameCache !== null) return Promise.resolve(nameCache);
  const fromLogin = () => {
    const u = userInfo().username.replace(/[._\d]+/g, " ").trim().split(/\s+/)[0] ?? "";
    return u ? u[0].toUpperCase() + u.slice(1) : "";
  };
  return new Promise((resolve) => {
    execFile("/usr/bin/id", ["-F"], { timeout: 2000 }, (err, stdout) => {
      const full = err ? "" : stdout.trim();
      const first = full.split(/\s+/)[0] || fromLogin();
      nameCache = first ? first[0].toUpperCase() + first.slice(1) : "";
      resolve(nameCache);
    });
  });
}

/** Parse the sidecar's greet replies. */
export function parseGreetLine(line: string): { id: string; text: string | null } | null {
  const m = /^ai (greet|greet-error) ([\w-]+)(?: (\S+))?$/.exec(line.trim());
  if (!m) return null;
  if (m[1] === "greet-error") return { id: m[2], text: null };
  return { id: m[2], text: Buffer.from(m[3] ?? "", "base64").toString("utf8").trim() || null };
}

const pendingGreets = new Map<string, (text: string | null) => void>();
let listening = false;
let seq = 0;

/** Ask the model for a line; null when it can't (or takes longer than `timeoutMs`). */
function modelLine(facts: string, timeoutMs: number): Promise<string | null> {
  if (assistantSupport() !== "available") return Promise.resolve(null);
  if (!listening) {
    listening = true;
    onLine((line) => {
      const reply = parseGreetLine(line);
      if (!reply) return;
      pendingGreets.get(reply.id)?.(reply.text);
      pendingGreets.delete(reply.id);
    });
  }
  const id = `g${++seq}`;
  return new Promise((resolve) => {
    const timer = setTimeout(() => {
      pendingGreets.delete(id);
      resolve(null);
    }, timeoutMs);
    pendingGreets.set(id, (text) => {
      clearTimeout(timer);
      resolve(text);
    });
    if (!send(`ai greet ${id} ${Buffer.from(facts, "utf8").toString("base64")}`)) {
      clearTimeout(timer);
      pendingGreets.delete(id);
      resolve(null);
    }
  });
}

/** Keep the model honest about length: one sentence-ish, no runaway text. */
export function tidyLine(text: string): string {
  const one = text.replace(/\s+/g, " ").trim().replace(/^["'“”]+|["'“”]+$/g, "").trim();
  return one.length > 140 ? `${one.slice(0, 137).replace(/\s+\S*$/, "")}…` : one;
}

const escape = (s: string) => s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");

/**
 * The title already says hello and the name, so drop the model's own opener
 * ("Good night, Sam. Ready…" → "Ready…"). Keeps the line if nothing is left.
 */
export function dropSalutation(line: string, name: string): string {
  const who = name ? `(?:\\s*,?\\s*${escape(name)})?` : "";
  const re = new RegExp(
    `^(?:(?:good (?:morning|afternoon|evening|night)|hey there|hi|hey|hello|welcome back)${who}|${name ? escape(name) : "(?!)"})\\s*[,.!—–-]*\\s*`,
    "i",
  );
  const rest = line.replace(re, "").trim();
  if (!rest || rest === line) return line;
  return rest[0].toUpperCase() + rest.slice(1);
}

export async function composeGreeting(
  facts: Omit<GreetingFacts, "name" | "date">,
  timeoutMs = 7000,
): Promise<Greeting> {
  const full: GreetingFacts = { ...facts, name: await firstName(), date: new Date() };
  const title = greetingTitle(full.name, full.date, full.occasion);
  const line = await modelLine(factsText(full), timeoutMs);
  if (line) return { title, line: dropSalutation(tidyLine(line), full.name), ai: true };
  return { title, line: fallbackLine(full), ai: false };
}

/** At launch the sidecar answers `ai caps` a moment later; wait for it (briefly). */
export function waitForAssistant(ms: number): Promise<void> {
  if (assistantSupport() !== "no-helper") return Promise.resolve();
  return new Promise((resolve) => {
    const timer = setTimeout(done, ms);
    const off = onAssistantSupport(done);
    function done() {
      clearTimeout(timer);
      off();
      resolve();
    }
  });
}
