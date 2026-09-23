import { onLine, send } from "./native-helper";

/**
 * Voice mode, relayed to the native sidecar (Swift): AVAudioEngine plus the
 * on-device SpeechAnalyzer transcriber to listen, AVSpeechSynthesizer to speak.
 * Nothing is recorded or sent anywhere; audio lives only in the sidecar.
 */

export type VoiceEvent =
  | { id: string; type: "listening" }
  | { id: string; type: "status"; status: string }
  | { id: string; type: "level"; level: number }
  | { id: string; type: "partial"; text: string }
  | { id: string; type: "final"; text: string }
  | { id: string; type: "error"; reason: string }
  | { id: ""; type: "spoken" };

const decode = (b64: string): string => Buffer.from(b64, "base64").toString("utf8");

export function parseVoiceLine(line: string): VoiceEvent | null {
  const t = line.trim();
  if (t === "speak done") return { id: "", type: "spoken" };
  const m = /^voice (listening|status|level|partial|final|error) ([\w-]+)(?: (\S+))?$/.exec(t);
  if (!m) return null;
  const [, type, id, arg = ""] = m;
  switch (type) {
    case "listening":
      return { id, type: "listening" };
    case "status":
      return { id, type: "status", status: arg };
    case "level": {
      const level = Number(arg);
      return Number.isFinite(level) ? { id, type: "level", level: Math.max(0, Math.min(1, level)) } : null;
    }
    case "partial":
      return { id, type: "partial", text: decode(arg) };
    case "final":
      return { id, type: "final", text: decode(arg) };
    default:
      return { id, type: "error", reason: arg || "unknown" };
  }
}

const safeId = (id: string) => id.replace(/[^\w-]/g, "").slice(0, 32) || "v";

export function initVoice(onEvent: (event: VoiceEvent) => void): void {
  onLine((line) => {
    const event = parseVoiceLine(line);
    if (event) onEvent(event);
  });
}

export function startListening(id: string): boolean {
  return send(`voice start ${safeId(id)}`);
}

export function stopListening(id: string): void {
  send(`voice stop ${safeId(id)}`);
}

export function speak(text: string): void {
  const clean = text.trim().slice(0, 2000);
  if (clean) send(`speak ${Buffer.from(clean, "utf8").toString("base64")}`);
}

export function stopSpeaking(): void {
  send("speak stop");
}
