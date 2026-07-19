// macOS-style window controls for our frameless windows. Red closes, yellow
// minimizes (when offered); glyphs appear on hover, exactly like the system's.
export function TrafficLights({
  onClose,
  onMinimize,
}: {
  onClose: () => void;
  onMinimize?: () => void;
}) {
  return (
    <div className="traffic-lights">
      <button className="tl tl-close" aria-label="Close window" onClick={onClose}>
        <svg viewBox="0 0 10 10" aria-hidden>
          <path d="M2.2 2.2 L7.8 7.8 M7.8 2.2 L2.2 7.8" />
        </svg>
      </button>
      {onMinimize && (
        <button className="tl tl-min" aria-label="Minimize window" onClick={onMinimize}>
          <svg viewBox="0 0 10 10" aria-hidden>
            <path d="M2 5 H8" />
          </svg>
        </button>
      )}
    </div>
  );
}
