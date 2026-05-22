#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SNAPSHOT_OUT_DIR="${SNAPSHOT_OUT_DIR:-$PROJECT_ROOT/evidence/snapshots}"
mkdir -p "$SNAPSHOT_OUT_DIR"

case_name="${1:-manual}"
target="${2:-agent-app-leak}"
timestamp="$(date '+%Y%m%d_%H%M%S')"
snapshot_file="$SNAPSHOT_OUT_DIR/${case_name}_${timestamp}.txt"

root_pid="$(pgrep -x "$target" | head -n 1 || true)"

child_pids_of() {
  local parent="$1"
  pgrep -P "$parent" || true
}

pid_family_of() {
  local root="$1"
  printf '%s\n' "$root"
  child_pids_of "$root"
}

{
  echo "## time"
  date
  echo
  echo "## env"
  env | grep -E '^(AGENT_|MEMORY_LIMIT|CPU_MAX_OCCUPY|MULTI_THREAD_ENABLE)=' | sort || true
  echo
  echo "## ps -ef"
  ps -ef | grep "$target" | grep -v grep || true
  echo

  if [[ -n "$root_pid" ]]; then
    pid_family="$(pid_family_of "$root_pid" | awk '!seen[$1]++' | xargs || true)"
    pid_csv="${pid_family// /,}"

    echo "## pid family"
    echo "ROOT_PID=$root_pid"
    echo "PID_FAMILY=$pid_family"
    echo
    echo "## ps"
    ps -p "$pid_csv" -o pid,ppid,user,stat,pcpu,pmem,rss,vsz,nlwp,etime,cmd || true
    echo
    echo "## ps -L"
    ps -L -p "$pid_csv" -o pid,tid,stat,pcpu,pmem,etime,comm || true
    echo
    echo "## top"
    top -b -n 1 -p "$pid_csv" || true
    echo
    echo "## top -H"
    top -b -H -n 1 -p "$pid_csv" || true
  else
    echo "No PID found for $target"
  fi
} | tee "$snapshot_file"

echo "Snapshot saved: $snapshot_file"
