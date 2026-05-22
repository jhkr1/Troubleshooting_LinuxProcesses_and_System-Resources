#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
MONITOR_OUT_DIR="${MONITOR_OUT_DIR:-$PROJECT_ROOT/evidence/monitor}"
mkdir -p "$MONITOR_OUT_DIR"

target="${1:-agent-app-leak}"
case_name="${2:-manual}"
interval="${3:-2}"

timestamp="$(date '+%Y%m%d_%H%M%S')"
log_file="$MONITOR_OUT_DIR/${case_name}_${timestamp}.log"
csv_file="$MONITOR_OUT_DIR/${case_name}_${timestamp}.csv"

find_root_pid() {
  pgrep -x "$target" | head -n 1 || true
}

child_pids_of() {
  local parent="$1"
  pgrep -P "$parent" || true
}

pid_family_of() {
  local root="$1"
  printf '%s\n' "$root"
  child_pids_of "$root"
}

echo "Waiting for process: $target"
deadline=$((SECONDS + 30))
root_pid=""
while [[ "$SECONDS" -lt "$deadline" ]]; do
  root_pid="$(find_root_pid)"
  if [[ -n "$root_pid" ]]; then
    break
  fi
  sleep 1
done

if [[ -z "$root_pid" ]]; then
  echo "ERROR: process not found: $target" | tee "$log_file"
  exit 1
fi

echo "time,root_pid,pid_family,cpu_percent,mem_percent,rss_kb,vsz_kb,threads,elapsed" > "$csv_file"
echo "Monitoring root PID=$root_pid, case=$case_name, interval=${interval}s" | tee "$log_file"

while kill -0 "$root_pid" 2>/dev/null; do
  now="$(date '+%Y-%m-%d %H:%M:%S')"
  pid_family="$(pid_family_of "$root_pid" | awk '!seen[$1]++' | xargs || true)"
  pid_csv="${pid_family// /,}"
  ps_line="$(ps -p "$pid_csv" -o %cpu=,%mem=,rss=,vsz=,nlwp=,etime= 2>/dev/null | awk '
    {
      cpu += $1
      mem += $2
      rss += $3
      vsz += $4
      threads += $5
      elapsed = $6
    }
    END {
      if (NR > 0) {
        printf "%.1f %.1f %d %d %d %s\n", cpu, mem, rss, vsz, threads, elapsed
      }
    }
  ' || true)"
  if [[ -z "$ps_line" ]]; then
    break
  fi

  read -r cpu mem rss vsz threads elapsed <<< "$ps_line"
  printf '%s,%s,"%s",%s,%s,%s,%s,%s,%s\n' "$now" "$root_pid" "$pid_family" "$cpu" "$mem" "$rss" "$vsz" "$threads" "$elapsed" >> "$csv_file"
  printf '[%s] PROCESS:%s ROOT_PID:%s PID_FAMILY:"%s" CPU:%s%% MEM:%s%% RSS:%sKB VSZ:%sKB THR:%s ELAPSED:%s\n' \
    "$now" "$target" "$root_pid" "$pid_family" "$cpu" "$mem" "$rss" "$vsz" "$threads" "$elapsed" | tee -a "$log_file"
  sleep "$interval"
done

echo "Process ended or disappeared: root PID=$root_pid" | tee -a "$log_file"
