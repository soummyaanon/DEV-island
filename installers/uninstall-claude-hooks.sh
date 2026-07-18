#!/usr/bin/env bash
# Remove Agent Island's hooks from ~/.claude/settings.json, leaving your own
# hooks and every other setting untouched. Pass --dry-run to preview.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SETTINGS="${CLAUDE_SETTINGS:-$HOME/.claude/settings.json}"

node "$SCRIPT_DIR/merge-claude-settings.mjs" uninstall --settings "$SETTINGS" "$@"
