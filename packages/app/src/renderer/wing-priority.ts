/**
 * What the collapsed wings show. Seven candidates, one winner, strict order:
 * an agent that needs you or is working always beats ambience, and a live
 * activity (battery moment, Focus change) never interrupts an agent. An
 * agent's own moment — it just finished or failed — interrupts the others'
 * work for a few seconds: that IS the notification.
 */

export type WingContent =
  | "attention"
  | "moment"
  | "working"
  | "activity"
  | "low-battery"
  | "weather"
  | "empty";

export interface WingInputs {
  needsYou: number;
  active: number;
  /** An agent just finished or failed: its avatar takes a short bow. */
  moment?: boolean;
  /** A transient live activity is currently showing. */
  activity: boolean;
  lowBattery: boolean;
  weather: boolean;
}

export function wingContent(i: WingInputs): WingContent {
  if (i.needsYou > 0) return "attention";
  if (i.moment) return "moment";
  if (i.active > 0) return "working";
  if (i.activity) return "activity";
  if (i.lowBattery) return "low-battery";
  if (i.weather) return "weather";
  return "empty";
}
