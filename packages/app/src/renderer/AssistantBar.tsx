import { useEffect, useRef, useState } from "react";
import { createPortal } from "react-dom";
import type { SessionSnapshot } from "@agent-island/shared";
import { AgentOrb } from "./agent-avatar";
import { assistantContext, assistantOrbState, findSessionByProject } from "./assistant-context";
import { Icon } from "./Icons";
import { FieldBeam } from "./FieldBeam";

/**
 * The island's Siri: an agent backed by Apple's on-device model. It answers,
 * and it acts — opens apps and pages, searches, reads and fills the clipboard,
 * sets the volume, starts timers, jumps to sessions — showing each step as it
 * goes. Anything that does real work for you (typing into an agent, running
 * one of your Shortcuts) is only proposed, and waits here for your click.
 *
 * The orb is the whole status language; see assistantOrbState.
 */

interface Turn {
  id: string;
  question: string;
  answer: string;
  status: "thinking" | "streaming" | "done" | "error";
  error?: string;
  /** What it did along the way, in order ("Opening Safari"). */
  steps: string[];
  /** The tool running right now; cleared when words arrive. */
  tool: string | null;
  /** Web results the answer was written from. */
  sources?: Array<{ title: string; url: string }>;
}

/** Waiting for the user's click before anything happens. */
type Proposal =
  | { id: string; kind: "draft"; project: string; message: string }
  | { id: string; kind: "shortcut"; name: string; status?: "running" | "failed" };

/** Past this with nothing back, "connecting" becomes "thinking". */
const SETTLE_MS = 900;

const VOICE_ERRORS: Record<string, string> = {
  "mic-denied": "Allow the microphone for Agent Island in System Settings → Privacy & Security.",
  "model-unavailable": "The on-device speech model isn't available yet.",
  "no-microphone": "No microphone found.",
  os: "Voice needs macOS 26 or later.",
};

const ERROR_TEXT: Record<string, string> = {
  guardrail: "Apple Intelligence declined to answer that.",
  "context-full": "That chat got too long — starting fresh.",
  cancelled: "Stopped.",
  timeout: "That took too long, so I stopped. Try asking again.",
  "model-failed": "Apple Intelligence couldn't answer that one. Try rephrasing.",
  unavailable: "Apple Intelligence isn't available right now.",
};

/** How many past exchanges stay on screen; the model keeps the rest. */
const VISIBLE_TURNS = 3;

export function AssistantBar({
  sessions,
  hovering,
  paused,
  onFocusChange,
  onLiveChange,
  onClose,
  fieldSlot = null,
  voiceEnabled = true,
  speakReplies = true,
  basic = false,
}: {
  sessions: SessionSnapshot[];
  /** Pointer over the island — leaving with nothing typed releases focus. */
  hovering: boolean;
  paused: boolean;
  onFocusChange: (focused: boolean) => void;
  /** An answer started or stopped streaming. */
  onLiveChange?: (live: boolean) => void;
  onClose: () => void;
  /** Where the input goes (the footer's left slot); inline when null. */
  fieldSlot?: HTMLElement | null;
  /** Settings → Intelligence: the mic button, and reading answers aloud. */
  voiceEnabled?: boolean;
  speakReplies?: boolean;
  /** No on-device model here: the commands still work, chat doesn't. */
  basic?: boolean;
}) {
  const [text, setText] = useState("");
  const [focused, setFocused] = useState(false);
  const [turns, setTurns] = useState<Turn[]>([]);
  const [drafts, setDrafts] = useState<Proposal[]>([]);
  // Flips once a question has been out for SETTLE_MS without a reply.
  const [settled, setSettled] = useState(false);
  // Voice: the turn being heard (null when not listening), and whether the
  // answer is being read aloud.
  const [voice, setVoice] = useState<{ id: string; phase: "starting" | "downloading" | "listening" } | null>(null);
  const [speaking, setSpeaking] = useState(false);
  const [voiceNote, setVoiceNote] = useState<string | null>(null);
  // Questions that were spoken get spoken answers.
  const spokenTurns = useRef(new Set<string>());
  const voiceRef = useRef(voice);
  voiceRef.current = voice;
  const speakRepliesRef = useRef(speakReplies);
  speakRepliesRef.current = speakReplies;
  const inputRef = useRef<HTMLInputElement>(null);
  const seq = useRef(0);
  const sessionsRef = useRef(sessions);
  sessionsRef.current = sessions;

  const live = turns.find((t) => t.status === "thinking" || t.status === "streaming") ?? null;
  const isLive = live !== null;
  useEffect(() => {
    onLiveChange?.(isLive);
  }, [isLive, onLiveChange]);
  useEffect(() => () => onLiveChange?.(false), [onLiveChange]);
  const liveId = live?.id ?? null;
  useEffect(() => {
    setSettled(false);
    if (!liveId) return;
    const t = window.setTimeout(() => setSettled(true), SETTLE_MS);
    return () => window.clearTimeout(t);
  }, [liveId]);

  // Focus on open; closing the bar ends the conversation, so the next one
  // starts with the model's whole (small) context window.
  useEffect(() => {
    requestAnimationFrame(() => inputRef.current?.focus());
    return () => {
      window.agentIsland.resetAssistant();
      if (voiceRef.current) window.agentIsland.stopVoice(voiceRef.current.id);
      window.agentIsland.stopSpeaking();
    };
  }, []);

  useEffect(
    () =>
      window.agentIsland.onAssistantEvent((event) => {
        if (event.type === "action") {
          const a = event.action;
          if (a.kind === "sources") {
            setTurns((all) => all.map((t) => (t.id === event.id ? { ...t, sources: a.sources } : t)));
            return;
          }
          const proposal: Proposal | null =
            a.kind === "draft" && a.message.trim()
              ? { id: `${event.id}-d`, kind: "draft", project: a.project, message: a.message }
              : a.kind === "shortcut"
                ? { id: `${event.id}-s-${a.name}`, kind: "shortcut", name: a.name }
                : null;
          if (proposal) {
            setDrafts((d) => [...d.filter((x) => x.id !== proposal.id), proposal]);
            window.agentIsland.haptic?.("tick");
          }
          return;
        }
        if (event.type === "tool") {
          setTurns((all) =>
            all.map((t) => (t.id === event.id ? { ...t, tool: event.name, steps: [...t.steps, event.step] } : t)),
          );
          return;
        }
        setTurns((all) =>
          all.map((t) => {
            if (t.id !== event.id) return t;
            if (event.type === "delta") return { ...t, answer: event.text, status: "streaming", tool: null };
            if (event.type === "done") {
              if (spokenTurns.current.has(t.id) && t.answer.trim() && speakRepliesRef.current) {
                spokenTurns.current.delete(t.id);
                window.agentIsland.speak(t.answer);
                setSpeaking(true);
              }
              return { ...t, status: "done", tool: null };
            }
            return { ...t, status: "error", tool: null, error: ERROR_TEXT[event.reason] ?? ERROR_TEXT.unavailable };
          }),
        );
      }),
    [],
  );

  // Moving off the island with nothing typed lets it close, like the prompt bar.
  useEffect(() => {
    if (!hovering && text.trim() === "" && !live) inputRef.current?.blur();
  }, [hovering, text, live]);

  const ask = (spokenQuestion?: string) => {
    const question = (spokenQuestion ?? text).trim();
    if (!question) return;
    window.agentIsland.stopSpeaking();
    setSpeaking(false);
    seq.current += 1;
    const id = `q${Date.now().toString(36)}${seq.current}`;
    if (spokenQuestion !== undefined) spokenTurns.current.add(id);
    setTurns((all) => [...all, { id, question, answer: "", status: "thinking" as const, steps: [], tool: null }].slice(-VISIBLE_TURNS));
    setText("");
    window.agentIsland.haptic?.("tick");
    window.agentIsland.askAssistant(id, question, assistantContext(sessionsRef.current, Date.now()));
  };

  const accept = (p: Proposal) => {
    window.agentIsland.haptic?.("commit");
    if (p.kind === "draft") {
      const target = findSessionByProject(sessionsRef.current, p.project);
      setDrafts((d) => d.filter((x) => x.id !== p.id));
      if (target) window.agentIsland.sendPrompt(target, p.message);
      return;
    }
    setDrafts((d) => d.map((x) => (x.id === p.id ? { ...p, status: "running" } : x)));
    void window.agentIsland.runShortcut(p.name).then((ok) => {
      if (ok) setDrafts((d) => d.filter((x) => x.id !== p.id));
      else setDrafts((d) => d.map((x) => (x.id === p.id ? { ...p, status: "failed" } : x)));
    });
  };

  // Voice: live words fill the field; the final sends itself.
  const askRef = useRef(ask);
  askRef.current = ask;
  useEffect(
    () =>
      window.agentIsland.onVoiceEvent((event) => {
        if (event.type === "spoken") {
          setSpeaking(false);
          return;
        }
        const current = voiceRef.current;
        if (!current || event.id !== current.id) return;
        switch (event.type) {
          case "listening":
            setVoice({ ...current, phase: "listening" });
            break;
          case "status":
            if (event.status === "downloading") setVoice({ ...current, phase: "downloading" });
            break;
          case "partial":
            setText(event.text);
            break;
          case "final":
            setVoice(null);
            setText("");
            if (event.text.trim()) askRef.current(event.text);
            break;
          case "error":
            setVoice(null);
            if (event.reason !== "superseded") setVoiceNote(VOICE_ERRORS[event.reason] ?? "Voice isn't available right now.");
            break;
        }
      }),
    [],
  );

  const toggleVoice = () => {
    window.agentIsland.haptic?.("tick");
    if (voice) {
      window.agentIsland.stopVoice(voice.id);
      return;
    }
    window.agentIsland.stopSpeaking();
    setSpeaking(false);
    setVoiceNote(null);
    setText("");
    seq.current += 1;
    const id = `v${Date.now().toString(36)}${seq.current}`;
    setVoice({ id, phase: "starting" });
    window.agentIsland.startVoice(id);
  };

  const orb = assistantOrbState({
    sent: live?.status === "thinking",
    settled,
    tool: live?.tool ?? null,
    streaming: live?.status === "streaming",
    proposing: drafts.length > 0,
    typing: voice !== null || (focused && text !== ""),
  });

  const orbResting = !live && drafts.length === 0 && voice === null && !(focused && text !== "");

  const field = (
    <FieldBeam focused={focused} loading={live?.status === "thinking"} paused={paused}>
      <form
        className="prompt-bar assistant-bar"
        onSubmit={(e) => {
          e.preventDefault();
          ask();
        }}
      >
        {/* Frozen at rest: an orb only moves while something is actually happening. */}
        <AgentOrb state={orb} tint={live ? "#b18cff" : undefined} paused={paused || orbResting} />
        <input
          ref={inputRef}
          className="prompt-input"
          type="text"
          value={text}
          placeholder={
            voice
              ? voice.phase === "downloading"
                ? "Getting the speech model…"
                : voice.phase === "listening"
                  ? "Listening…"
                  : "Starting the mic…"
              : speaking
                ? "Speaking…"
                : basic
                  ? "Open, search, set a timer…"
                  : "Ask anything…"
          }
          aria-label="Ask Apple Intelligence about your agents"
          spellCheck={false}
          onChange={(e) => {
            setText(e.target.value);
            if (speaking) {
              window.agentIsland.stopSpeaking();
              setSpeaking(false);
            }
          }}
          onFocus={() => {
            setFocused(true);
            onFocusChange(true);
          }}
          onBlur={() => {
            setFocused(false);
            onFocusChange(false);
          }}
          onKeyDown={(e) => {
            if (e.key !== "Escape") return;
            if (live) {
              window.agentIsland.cancelAssistant(live.id);
              return;
            }
            setText("");
            e.currentTarget.blur();
            onClose();
          }}
        />
        {voiceEnabled && !live && (text.trim() === "" || voice) && (
          <button
            className={`ctl icon voice-toggle${voice ? " on" : ""}${speaking ? " speaking" : ""}`}
            type="button"
            title={voice ? "Stop listening" : speaking ? "Stop speaking" : "Speak your question"}
            aria-label={voice ? "Stop listening" : speaking ? "Stop speaking" : "Speak your question"}
            aria-pressed={voice !== null}
            onClick={() => {
              if (speaking && !voice) {
                window.agentIsland.stopSpeaking();
                setSpeaking(false);
                return;
              }
              toggleVoice();
            }}
          >
            <Icon name="mic" />
          </button>
        )}
        {live ? (
          <button
            className="ctl icon prompt-send"
            type="button"
            title="Stop"
            aria-label="Stop answering"
            onClick={() => window.agentIsland.cancelAssistant(live.id)}
          >
            <Icon name="close" />
          </button>
        ) : (text.trim() === "" && voiceEnabled) || voice ? null : (
          <button
            className="ctl icon prompt-send"
            type="submit"
            title="Ask"
            aria-label="Ask"
            disabled={!text.trim()}
          >
            <Icon name="send" />
          </button>
        )}
      </form>
    </FieldBeam>
  );

  return (
    <div className={`assistant${live ? " live" : ""}`} onClick={(e) => e.stopPropagation()}>
      {turns.length > 0 && (
        <ol className="assistant-turns" aria-live="polite">
          {turns.map((t) => (
            <li key={t.id} className={`assistant-turn ${t.status}`}>
              <div className="assistant-q">{t.question}</div>
              {t.steps.length > 0 && (
                <ul className="assistant-steps">
                  {t.steps.map((step, i) => (
                    <li key={i} className={t.tool && i === t.steps.length - 1 ? "running" : "done"}>
                      {step}
                    </li>
                  ))}
                </ul>
              )}
              <div className="assistant-a">
                {t.status === "error" ? (
                  <span className="assistant-error">{t.error}</span>
                ) : t.answer ? (
                  <>
                    {t.answer}
                    {t.status === "done" && (
                      <button
                        type="button"
                        className="ctl icon assistant-copy"
                        title="Copy answer"
                        aria-label="Copy answer"
                        onClick={() => {
                          void navigator.clipboard.writeText(t.answer);
                          window.agentIsland.haptic?.("tick");
                        }}
                      >
                        <Icon name="copy" size={12} />
                      </button>
                    )}
                  </>
                ) : (
                  <span className="assistant-wait">Thinking…</span>
                )}
              </div>
              {t.sources && t.sources.length > 0 && (
                <ul className="assistant-sources" aria-label="Sources">
                  {t.sources.map((src) => {
                    const host = new URL(src.url).hostname.replace(/^www\./, "");
                    return (
                      <li key={src.url}>
                        <button
                          type="button"
                          className="assistant-source"
                          title={src.title || src.url}
                          onClick={() => window.agentIsland.openSource(src.url)}
                        >
                          {host}
                        </button>
                      </li>
                    );
                  })}
                </ul>
              )}
            </li>
          ))}
        </ol>
      )}
      {voiceNote && <div className="assistant-voice-note">{voiceNote}</div>}
      {drafts.map((d) => {
        const target = d.kind === "draft" ? findSessionByProject(sessions, d.project) : null;
        const ready = d.kind === "draft" ? target !== null : d.status !== "running";
        return (
          <div className={`assistant-draft ${d.kind}`} key={d.id}>
            <div className="assistant-draft-text">
              {d.kind === "draft" ? (
                <>
                  <span className="assistant-draft-to">To {target ? d.project : `${d.project} (not running)`}</span>
                  <span>{d.message}</span>
                </>
              ) : (
                <>
                  <span className="assistant-draft-to">
                    {d.status === "failed" ? "Shortcut failed" : d.status === "running" ? "Running shortcut…" : "Run shortcut"}
                  </span>
                  <span>{d.name}</span>
                </>
              )}
            </div>
            <button type="button" className="btn allow" disabled={!ready} onClick={() => accept(d)}>
              {d.kind === "draft" ? "Send" : d.status === "failed" ? "Retry" : "Run"}
            </button>
            <button
              type="button"
              className="ctl icon"
              aria-label="Dismiss"
              title="Dismiss"
              onClick={() => setDrafts((all) => all.filter((x) => x.id !== d.id))}
            >
              <Icon name="close" />
            </button>
          </div>
        );
      })}
      {fieldSlot ? createPortal(field, fieldSlot) : field}
    </div>
  );
}
