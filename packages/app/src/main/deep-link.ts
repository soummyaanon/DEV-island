/**
 * `agent-island://` deep links.
 *
 * The app cannot read Focus state (it sits behind Full Disk Access with no
 * public API), but a Shortcuts automation can open a URL when a Focus turns
 * on or off — so the scheme is how Focus reaches us. `toggle` and `settings`
 * come almost for free once the handler exists.
 *
 * Any local app can open the scheme; the worst a stranger can do is mute
 * sounds or open a window — the same exposure as the tray toggle.
 */

export type DeepLink =
  | { kind: "focus"; active: boolean; name: string | null }
  | { kind: "toggle" }
  | { kind: "settings" };

export const DEEP_LINK_SCHEME = "agent-island";
const MAX_NAME = 40;

export function parseDeepLink(raw: string): DeepLink | null {
  let url: URL;
  try {
    url = new URL(raw);
  } catch {
    return null;
  }
  if (url.protocol !== `${DEEP_LINK_SCHEME}:`) return null;
  const host = url.hostname.toLowerCase();
  const path = url.pathname.replace(/\/+$/, "").toLowerCase();

  if (host === "focus") {
    if (path !== "/on" && path !== "/off") return null;
    const rawName = url.searchParams.get("name")?.trim() ?? "";
    const name = rawName ? rawName.slice(0, MAX_NAME) : null;
    return { kind: "focus", active: path === "/on", name };
  }
  if (host === "toggle" && path === "") return { kind: "toggle" };
  if (host === "settings" && path === "") return { kind: "settings" };
  return null;
}

/** The two URLs a Focus automation needs, for Settings to show and copy. */
export function focusLinks(): { on: string; off: string } {
  return {
    on: `${DEEP_LINK_SCHEME}://focus/on?name=Work`,
    off: `${DEEP_LINK_SCHEME}://focus/off`,
  };
}
