#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

cd "$PROJECT_ROOT"

if [[ "$(uname -s)" != "Linux" ]]; then
  echo "ERROR: Run this inside OrbStack Linux, not macOS."
  exit 1
fi

if [[ "$(id -u)" == "0" ]]; then
  echo "ERROR: Run as a non-root user."
  exit 1
fi

missing=()
for cmd in ps top pgrep ss awk grep tail tee date unzip file chmod mkdir xargs; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    missing+=("$cmd")
  fi
done

if [[ "${#missing[@]}" -gt 0 ]]; then
  echo "ERROR: Missing commands: ${missing[*]}"
  echo "Install them in Ubuntu with:"
  echo "  sudo apt update"
  echo "  sudo apt install -y procps psmisc iproute2 unzip file"
  exit 1
fi

APP_PATH="${APP_PATH:-$PROJECT_ROOT/agent-app-leak}"
AGENT_HOME="${AGENT_HOME:-$PROJECT_ROOT/.agent-home}"
AGENT_UPLOAD_DIR="${AGENT_UPLOAD_DIR:-$AGENT_HOME/upload_files}"
AGENT_KEY_PATH="${AGENT_KEY_PATH:-$AGENT_HOME/api_keys}"
AGENT_LOG_DIR="${AGENT_LOG_DIR:-$PROJECT_ROOT/evidence/logs}"
MONITOR_OUT_DIR="${MONITOR_OUT_DIR:-$PROJECT_ROOT/evidence/monitor}"
SNAPSHOT_OUT_DIR="${SNAPSHOT_OUT_DIR:-$PROJECT_ROOT/evidence/snapshots}"

if [[ ! -f "$APP_PATH" ]]; then
  unzip -n agent-app-leak.zip
fi

chmod +x "$APP_PATH"
mkdir -p "$AGENT_UPLOAD_DIR" "$AGENT_KEY_PATH" "$AGENT_LOG_DIR" "$MONITOR_OUT_DIR" "$SNAPSHOT_OUT_DIR" reports
printf '%s\n' 'agent_api_key_test' > "$AGENT_KEY_PATH/secret.key"
chmod 700 "$AGENT_KEY_PATH"
chmod 600 "$AGENT_KEY_PATH/secret.key"

echo "Prepared."
echo "APP_PATH=$APP_PATH"
echo "AGENT_HOME=$AGENT_HOME"
echo "AGENT_LOG_DIR=$AGENT_LOG_DIR"
file "$APP_PATH"
