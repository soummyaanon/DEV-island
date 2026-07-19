import { StrictMode, useEffect, useState } from "react";
import { createRoot } from "react-dom/client";
import { PixelSprite } from "./PixelSprite";
import { OpenAiSprite } from "./OpenAiSprite";
import { CursorSprite } from "./CursorSprite";
import { TrafficLights } from "./TrafficLights";
import "./styles/window-chrome.css";
import "./styles/onboarding.css";

interface OnboardingState {
  accessibilityTrusted: boolean;
  openAtLogin: boolean;
}

/** Animated mock of the island — the hero of the first-run window. */
function IslandDemo() {
  return (
    <div className="demo-strip" aria-hidden>
      <div className="demo-island">
        <div className="demo-band">
          <span className="demo-sprites">
            <PixelSprite live />
            <OpenAiSprite live />
            <CursorSprite live />
          </span>
          <span className="demo-count">3</span>
        </div>
        <div className="demo-rows">
          <div className="demo-row">
            <i className="demo-dot working" />
            <span className="demo-name">fix auth bug</span>
            <span className="demo-meta">claude · 28m</span>
          </div>
          <div className="demo-row">
            <i className="demo-dot working" />
            <span className="demo-name">backend server</span>
            <span className="demo-meta">codex · 1h</span>
          </div>
          <div className="demo-row">
            <i className="demo-dot done" />
            <span className="demo-name">optimize queries</span>
            <span className="demo-meta">cursor · done</span>
          </div>
        </div>
      </div>
    </div>
  );
}

function Onboarding() {
  const [state, setState] = useState<OnboardingState>({
    accessibilityTrusted: false,
    openAtLogin: false,
  });

  useEffect(() => {
    if (!window.agentIsland?.onboarding) return; // plain-browser preview
    void window.agentIsland.onboarding.getState().then(setState);
    return window.agentIsland.onboarding.onState(setState);
  }, []);

  return (
    <div className="onboard">
      <div className="drag-strip" />
      {/* Closing the intro still counts as onboarded — never trap the user. */}
      <TrafficLights onClose={() => window.agentIsland?.onboarding?.finish()} />
      <IslandDemo />

      <h1 className="ob-title">Agent Island</h1>
      <p className="ob-sub">
        Your coding agents live at the notch. Claude Code, Codex, and Cursor sessions appear the
        moment they start — watch them work, approve with <kbd>⌘Y</kbd>, answer questions with{" "}
        <kbd>⌘1–9</kbd>, and jump back to the right terminal in one click. Everything stays on this
        Mac.
      </p>

      <div className="ob-steps">
        <div className={`ob-step${state.accessibilityTrusted ? " done" : ""}`}>
          <div className="ob-step-text">
            <b>Answer from the notch</b>
            <span>
              Accessibility lets Agent Island press the option key in your terminal for you.
            </span>
          </div>
          {state.accessibilityTrusted ? (
            <span className="ob-check">✓ enabled</span>
          ) : (
            <button
              className="ob-btn"
              onClick={() => window.agentIsland.onboarding.enableAccessibility()}
            >
              Enable
            </button>
          )}
        </div>

        <div className={`ob-step${state.openAtLogin ? " done" : ""}`}>
          <div className="ob-step-text">
            <b>Always on your island</b>
            <span>Start automatically when you log in — silent, no Dock, no menu bar.</span>
          </div>
          {state.openAtLogin ? (
            <span className="ob-check">✓ enabled</span>
          ) : (
            <button className="ob-btn" onClick={() => window.agentIsland.onboarding.setLogin(true)}>
              Enable
            </button>
          )}
        </div>
      </div>

      <button className="ob-start" onClick={() => window.agentIsland.onboarding.finish()}>
        Take me to the island
      </button>
      <p className="ob-hint">Hover the notch anytime for sessions, sounds, and quit.</p>
    </div>
  );
}

createRoot(document.getElementById("root")!).render(
  <StrictMode>
    <Onboarding />
  </StrictMode>,
);
