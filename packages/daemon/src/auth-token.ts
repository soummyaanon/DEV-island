import { randomBytes, timingSafeEqual } from "node:crypto";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname } from "node:path";
import type { IncomingHttpHeaders } from "node:http";

/**
 * Read the shared token, creating a fresh random one (0600) on first run.
 * Adapters read the same file and send it back as a header.
 */
export function ensureToken(tokenPath: string): string {
  if (existsSync(tokenPath)) {
    const existing = readFileSync(tokenPath, "utf8").trim();
    if (existing) return existing;
  }
  const token = randomBytes(32).toString("hex");
  mkdirSync(dirname(tokenPath), { recursive: true });
  writeFileSync(tokenPath, `${token}\n`, { mode: 0o600 });
  return token;
}

/** Pull the token from `Authorization: Bearer <t>` or `X-Agent-Island-Token`. */
export function extractToken(headers: IncomingHttpHeaders): string | undefined {
  const custom = headers["x-agent-island-token"];
  if (typeof custom === "string" && custom.trim()) return custom.trim();

  const auth = headers["authorization"];
  if (typeof auth === "string") {
    const match = /^Bearer\s+(.+)$/i.exec(auth.trim());
    if (match) return match[1].trim();
  }
  return undefined;
}

/** Constant-time comparison; false on any mismatch or missing value. */
export function verifyToken(provided: string | undefined, expected: string): boolean {
  if (!provided) return false;
  const a = Buffer.from(provided);
  const b = Buffer.from(expected);
  if (a.length !== b.length) return false;
  return timingSafeEqual(a, b);
}
