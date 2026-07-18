#!/usr/bin/env bash
# Build agentislandd and register it as a launchd agent (starts at login).
# Idempotent: safe to re-run after code changes.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DAEMON_DIR="$REPO_ROOT/packages/daemon"
NODE_BIN="$(command -v node)"
LABEL="com.agentisland.daemon"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG_DIR="$HOME/.agent-island/logs"

if [ -z "$NODE_BIN" ]; then
  echo "error: node not found on PATH" >&2
  exit 1
fi

echo "==> Building daemon bundle"
(cd "$REPO_ROOT" && pnpm --filter @agent-island/daemon build)

if [ ! -f "$DAEMON_DIR/dist/main.cjs" ]; then
  echo "error: build did not produce $DAEMON_DIR/dist/main.cjs" >&2
  exit 1
fi

mkdir -p "$LOG_DIR" "$(dirname "$PLIST")"

echo "==> Writing $PLIST"
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$NODE_BIN</string>
    <string>$DAEMON_DIR/dist/main.cjs</string>
  </array>
  <key>WorkingDirectory</key>
  <string>$DAEMON_DIR</string>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>StandardOutPath</key>
  <string>$LOG_DIR/daemon.out.log</string>
  <key>StandardErrorPath</key>
  <string>$LOG_DIR/daemon.err.log</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>NODE_ENV</key>
    <string>production</string>
  </dict>
</dict>
</plist>
EOF

echo "==> Reloading launchd agent"
launchctl unload "$PLIST" 2>/dev/null || true
launchctl load "$PLIST"

echo "==> Done. Verify with:"
echo "    curl -s http://127.0.0.1:7433/health"
echo "    (token was written to ~/.agent-island/token)"
