/**
 * What the collapsed wings show. Six candidates, one winner, strict order:
 * an agent that needs you or is working always beats ambience, and a live
 * activity (battery moment, Focus change) never interrupts an agent.
 */

export type WingContent = "attention" | "working" | "activity" | "low-battery" | "weather" | "empty";

export interface WingInputs {
  needsYou: number;
  active: number;
  /** A transient live activity is currently showing. */
  activity: boolean;
  lowBattery: boolean;
  weather: boolean;
}

export function wingContent(i: WingInputs): WingContent {
  if (i.needsYou > 0) return "attention";
  if (i.active > 0) return "working";
  if (i.activity) return "activity";
  if (i.lowBattery) return "low-battery";
  if (i.weather) return "weather";
  return "empty";
}
