#!/usr/bin/env bash
# Remove the agentislandd launchd agent. Leaves ~/.agent-island (token, logs) intact.
set -euo pipefail

LABEL="com.agentisland.daemon"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

if [ -f "$PLIST" ]; then
  launchctl unload "$PLIST" 2>/dev/null || true
  rm -f "$PLIST"
  echo "Removed $LABEL ($PLIST)"
else
  echo "$LABEL not installed (no plist at $PLIST)"
fi
