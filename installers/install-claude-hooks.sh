#!/usr/bin/env bash
# Register Agent Island's HTTP hooks in ~/.claude/settings.json (safe merge).
# Idempotent. Pass --dry-run to preview without writing.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SETTINGS="${CLAUDE_SETTINGS:-$HOME/.claude/settings.json}"
URL="${AGENT_ISLAND_URL:-http://localhost:7433}"
TOKEN_FILE="${AGENT_ISLAND_TOKEN_FILE:-$HOME/.agent-island/token}"

# Ensure a shared token exists (same file the daemon reads).
if [ ! -s "$TOKEN_FILE" ]; then
  mkdir -p "$(dirname "$TOKEN_FILE")"
  node -e 'console.log(require("crypto").randomBytes(32).toString("hex"))' > "$TOKEN_FILE"
  chmod 600 "$TOKEN_FILE"
  echo "generated shared token at $TOKEN_FILE"
fi
TOKEN="$(tr -d '\n' < "$TOKEN_FILE")"

node "$SCRIPT_DIR/merge-claude-settings.mjs" install \
  --settings "$SETTINGS" --url "$URL" --token "$TOKEN" "$@"
