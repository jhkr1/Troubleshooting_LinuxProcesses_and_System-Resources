#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

APP_PATH="${APP_PATH:-$PROJECT_ROOT/agent-app-leak}"
AGENT_HOME="${AGENT_HOME:-$PROJECT_ROOT/.agent-home}"
AGENT_PORT="${AGENT_PORT:-15034}"
AGENT_UPLOAD_DIR="${AGENT_UPLOAD_DIR:-$AGENT_HOME/upload_files}"
AGENT_KEY_PATH="${AGENT_KEY_PATH:-$AGENT_HOME/api_keys}"
AGENT_LOG_DIR="${AGENT_LOG_DIR:-$PROJECT_ROOT/evidence/logs}"
MEMORY_LIMIT="${MEMORY_LIMIT:-128}"
CPU_MAX_OCCUPY="${CPU_MAX_OCCUPY:-50}"
MULTI_THREAD_ENABLE="${MULTI_THREAD_ENABLE:-true}"

export AGENT_HOME AGENT_PORT AGENT_UPLOAD_DIR AGENT_KEY_PATH AGENT_LOG_DIR
export MEMORY_LIMIT CPU_MAX_OCCUPY MULTI_THREAD_ENABLE

if [[ "$(id -u)" == "0" ]]; then
  echo "ERROR: agent-app-leak must be run as a non-root user."
  exit 1
fi

if [[ ! -x "$APP_PATH" ]]; then
  echo "ERROR: app is not executable. Run: ./scripts/prepare.sh"
  exit 1
fi

mkdir -p "$AGENT_UPLOAD_DIR" "$AGENT_KEY_PATH" "$AGENT_LOG_DIR"
printf '%s\n' 'agent_api_key_test' > "$AGENT_KEY_PATH/secret.key"

run_id="$(date '+%Y%m%d_%H%M%S')"
stdout_log="$AGENT_LOG_DIR/run_${run_id}.log"

echo "Starting agent-app-leak"
echo "MEMORY_LIMIT=$MEMORY_LIMIT"
echo "CPU_MAX_OCCUPY=$CPU_MAX_OCCUPY"
echo "MULTI_THREAD_ENABLE=$MULTI_THREAD_ENABLE"
echo "STDOUT_LOG=$stdout_log"

exec "$APP_PATH" 2>&1 | tee "$stdout_log"
