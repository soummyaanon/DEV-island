/**
 * Focus (Do Not Disturb) state, as told to us by a Shortcuts automation via
 * `agent-island://focus/on|off` (see deep-link.ts). Not persisted: a fresh
 * launch starts un-focused, and the "turns on" automation re-fires next time.
 */

export interface FocusState {
  active: boolean;
  name: string | null;
  /** ISO timestamp of the last change. */
  since: string;
}

type Listener = (state: FocusState) => void;
let listeners: Listener[] = [];
let current: FocusState = { active: false, name: null, since: new Date(0).toISOString() };

export function getFocus(): FocusState {
  return current;
}

export function onFocus(listener: Listener): () => void {
  listeners.push(listener);
  return () => {
    listeners = listeners.filter((l) => l !== listener);
  };
}

export function setFocus(active: boolean, name: string | null, now = new Date()): FocusState {
  current = { active, name: active ? name : null, since: now.toISOString() };
  for (const l of listeners) l(current);
  return current;
}

/** The footer chip's click: clears a Focus whose "off" automation never fired. */
export function clearFocus(): FocusState {
  return setFocus(false, null);
}
