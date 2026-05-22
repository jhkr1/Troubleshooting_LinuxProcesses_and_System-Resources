# Script Guide

이 문서는 `scripts/` 폴더의 쉘 스크립트를 설명한다. 목표는 단순히 “어떤 명령을 실행한다”가 아니라, 왜 이런 스크립트가 필요하고 각 줄이 무슨 일을 하는지 이해하는 것이다.

이번 미션에서 스크립트는 실험 장비다. 앱을 실행하는 도구, 관제 데이터를 남기는 도구, 특정 순간의 프로세스 상태를 저장하는 도구가 있어야 같은 실험을 다시 재현할 수 있다.

현재 스크립트는 4개다.

| 파일 | 역할 |
|---|---|
| `prepare.sh` | 실험 전 환경 준비 |
| `run_agent.sh` | 앱 실행과 로그 저장 |
| `monitor.sh` | 시간별 CPU/MEM/RSS/스레드 수 관제 |
| `snapshot.sh` | 특정 순간의 `ps`, `ps -L`, `top`, `top -H` 증거 저장 |

---

## 1. 쉘 스크립트를 읽기 전에

쉘 스크립트는 터미널에 직접 입력하던 명령어를 파일로 묶은 것이다.

터미널에서 이렇게 실행하던 일을:

```bash
mkdir -p evidence/logs
chmod +x agent-app-leak
MEMORY_LIMIT=64 ./scripts/run_agent.sh
```

파일에 적어두면 반복 실험이 쉬워진다.

```bash
./scripts/prepare.sh
```

이번 실습에서 스크립트를 쓰는 이유는 세 가지다.

```text
1. 매번 같은 환경을 만들기 위해
2. 실험 결과를 evidence 폴더에 자동 저장하기 위해
3. 평가자가 같은 순서로 다시 따라 할 수 있게 하기 위해
```

---

## 2. 자주 나오는 쉘 문법

### 2.1 Shebang

```bash
#!/usr/bin/env bash
```

파일 첫 줄의 이 문장은 “이 파일은 bash로 실행해 달라”는 뜻이다.

`bash`는 Linux에서 많이 쓰는 쉘이다. 쉘은 사용자의 명령을 읽고 운영체제에 전달하는 프로그램이다.

### 2.2 안전 옵션

```bash
set -euo pipefail
```

스크립트가 실패를 숨기지 않게 만드는 설정이다.

| 옵션 | 의미 |
|---|---|
| `-e` | 어떤 명령이 실패하면 스크립트를 중단 |
| `-u` | 없는 변수를 쓰면 중단 |
| `pipefail` | 파이프라인 중간 명령 실패도 실패로 처리 |

초보자에게는 조금 엄격해 보이지만, 실험 스크립트에서는 좋은 습관이다. 실패한 상태로 계속 진행하면 잘못된 evidence가 남을 수 있기 때문이다.

### 2.3 변수

```bash
PROJECT_ROOT="/some/path"
echo "$PROJECT_ROOT"
```

쉘 변수는 값을 이름에 담아두는 방식이다. 사용할 때는 `$`를 붙인다.

문자열 변수는 대부분 따옴표로 감싼다.

```bash
echo "$PROJECT_ROOT"
```

따옴표를 쓰는 이유는 경로에 공백이 있을 때도 안전하게 처리하기 위해서다.

### 2.4 기본값 문법

```bash
MEMORY_LIMIT="${MEMORY_LIMIT:-128}"
```

뜻:

```text
MEMORY_LIMIT 환경변수가 이미 있으면 그 값을 쓴다.
없으면 128을 쓴다.
```

그래서 아래처럼 실행하면 이번 한 번만 값을 바꿀 수 있다.

```bash
MEMORY_LIMIT=64 ./scripts/run_agent.sh
```

### 2.5 명령 치환

```bash
timestamp="$(date '+%Y%m%d_%H%M%S')"
```

`$(...)`는 괄호 안 명령의 출력 결과를 변수에 담는다.

예를 들어 현재 시간이 `20260522_190141`이면:

```text
timestamp=20260522_190141
```

이 값으로 로그 파일 이름을 만든다.

### 2.6 조건문

```bash
if [[ ! -x "$APP_PATH" ]]; then
  echo "ERROR"
  exit 1
fi
```

뜻:

```text
APP_PATH가 실행 가능한 파일이 아니면 에러를 출력하고 종료한다.
```

자주 보이는 파일 검사:

| 표현 | 의미 |
|---|---|
| `-f file` | 일반 파일인가 |
| `-x file` | 실행 가능한 파일인가 |
| `-z "$var"` | 문자열이 비어 있는가 |
| `-n "$var"` | 문자열이 비어 있지 않은가 |

### 2.7 파이프와 tee

```bash
exec "$APP_PATH" 2>&1 | tee "$stdout_log"
```

조각별 의미:

| 조각 | 의미 |
|---|---|
| `exec "$APP_PATH"` | 앱 실행 |
| `2>&1` | 에러 출력도 일반 출력과 합침 |
| `|` | 앞 명령의 출력을 뒤 명령으로 넘김 |
| `tee "$stdout_log"` | 화면에 보여주면서 파일에도 저장 |

이 한 줄 덕분에 실행 로그가 터미널에도 보이고 `evidence/logs/run_*.log`에도 저장된다.

---

## 3. prepare.sh

`prepare.sh`는 실험실을 정리하는 스크립트다. 앱을 실행하기 전에 필요한 디렉터리, 키 파일, 실행 권한을 준비한다.

실행:

```bash
cd /mnt/mac/Users/wlgjs060614351/Desktop/Troubleshooting_LinuxProcesses_and_System-Resources
./scripts/prepare.sh
```

### 3.1 프로젝트 경로 찾기

```bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_ROOT"
```

이 부분은 “스크립트가 어디서 실행되든 프로젝트 루트를 찾기 위한 코드”다.

| 변수 | 뜻 |
|---|---|
| `BASH_SOURCE[0]` | 현재 실행 중인 스크립트 파일 경로 |
| `dirname` | 파일 경로에서 디렉터리 부분만 추출 |
| `SCRIPT_DIR` | `scripts` 폴더 경로 |
| `PROJECT_ROOT` | 프로젝트 루트 경로 |

사용자가 실수로 다른 위치에서 실행해도 스크립트가 자기 위치를 기준으로 프로젝트 루트를 계산한다.

### 3.2 Linux와 일반 사용자 확인

```bash
if [[ "$(uname -s)" != "Linux" ]]; then
  echo "ERROR: Run this inside OrbStack Linux, not macOS."
  exit 1
fi
```

`uname -s`는 운영체제 이름을 출력한다. macOS에서 실행하면 `Darwin`, Linux에서 실행하면 `Linux`가 나온다.

```bash
if [[ "$(id -u)" == "0" ]]; then
  echo "ERROR: Run as a non-root user."
  exit 1
fi
```

`id -u`는 사용자 ID를 출력한다. root는 항상 `0`이다. 이 앱은 root가 아닌 일반 사용자로 실행해야 한다.

평가 답변:

```text
root로 실행하면 권한이 너무 커서 실제 서비스 사용자 환경과 다르고, 앱의 부트 체크 조건도 만족하지 못한다.
```

### 3.3 필요한 명령어 확인

```bash
missing=()
for cmd in ps top pgrep ss awk grep tail tee date unzip file chmod mkdir xargs; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    missing+=("$cmd")
  fi
done
```

`command -v`는 해당 명령어가 설치되어 있는지 확인한다.

필요 명령어:

| 명령어 | 쓰는 이유 |
|---|---|
| `ps` | 프로세스와 스레드 상태 확인 |
| `top` | CPU/MEM 상태 확인 |
| `pgrep` | 프로세스 이름으로 PID 검색 |
| `ss` | 포트 사용 여부 확인 |
| `awk` | 숫자 합산과 텍스트 처리 |
| `grep` | 로그 검색 |
| `tail` | 로그 마지막 부분 확인 |
| `tee` | 화면 출력과 파일 저장 동시 수행 |
| `date` | 로그 파일명 timestamp 생성 |
| `unzip` | zip 압축 해제 |
| `file` | 실행 파일 형식 확인 |
| `chmod` | 실행 권한 부여 |
| `mkdir` | 디렉터리 생성 |
| `xargs` | 여러 줄 출력을 한 줄로 정리 |

설치 명령:

```bash
sudo apt update
sudo apt install -y procps psmisc iproute2 unzip file
```

### 3.4 앱과 디렉터리 준비

```bash
APP_PATH="${APP_PATH:-$PROJECT_ROOT/agent-app-leak}"
AGENT_HOME="${AGENT_HOME:-$PROJECT_ROOT/.agent-home}"
AGENT_UPLOAD_DIR="${AGENT_UPLOAD_DIR:-$AGENT_HOME/upload_files}"
AGENT_KEY_PATH="${AGENT_KEY_PATH:-$AGENT_HOME/api_keys}"
AGENT_LOG_DIR="${AGENT_LOG_DIR:-$PROJECT_ROOT/evidence/logs}"
```

앱이 요구하는 환경 경로를 정한다.

```bash
if [[ ! -f "$APP_PATH" ]]; then
  unzip -n agent-app-leak.zip
fi
```

`agent-app-leak` 파일이 없으면 zip을 푼다. `-n`은 이미 있는 파일을 덮어쓰지 않는 옵션이다.

```bash
chmod +x "$APP_PATH"
mkdir -p "$AGENT_UPLOAD_DIR" "$AGENT_KEY_PATH" "$AGENT_LOG_DIR" "$MONITOR_OUT_DIR" "$SNAPSHOT_OUT_DIR" reports
printf '%s\n' 'agent_api_key_test' > "$AGENT_KEY_PATH/secret.key"
chmod 700 "$AGENT_KEY_PATH"
chmod 600 "$AGENT_KEY_PATH/secret.key"
```

여기서 하는 일:

```text
1. 앱에 실행 권한을 준다.
2. 업로드 디렉터리를 만든다.
3. API key 디렉터리를 만든다.
4. 로그/evidence 디렉터리를 만든다.
5. secret.key 파일을 만든다.
6. key 디렉터리와 파일 권한을 제한한다.
```

권한 의미:

| 권한 | 의미 |
|---|---|
| `700` | 소유자만 읽기/쓰기/실행 |
| `600` | 소유자만 읽기/쓰기 |

---

## 4. run_agent.sh

`run_agent.sh`는 앱 실행 담당이다. 환경변수를 설정하고, 실행 로그를 `evidence/logs`에 저장한다.

실행 예:

```bash
MEMORY_LIMIT=64 CPU_MAX_OCCUPY=100 MULTI_THREAD_ENABLE=false ./scripts/run_agent.sh
```

### 4.1 환경변수 기본값

```bash
AGENT_PORT="${AGENT_PORT:-15034}"
MEMORY_LIMIT="${MEMORY_LIMIT:-128}"
CPU_MAX_OCCUPY="${CPU_MAX_OCCUPY:-50}"
MULTI_THREAD_ENABLE="${MULTI_THREAD_ENABLE:-true}"
```

| 변수 | 의미 | 미션 조건 |
|---|---|---|
| `AGENT_PORT` | 앱이 바인딩할 포트 | `15034` |
| `MEMORY_LIMIT` | 앱 내부 메모리 제한 MB | `50~512` |
| `CPU_MAX_OCCUPY` | 앱 내부 CPU 제한 % | `10~100` |
| `MULTI_THREAD_ENABLE` | 멀티스레드 경로 사용 여부 | `true/false` |

환경변수는 앱 프로세스에게 전달되는 설정값이다. 코드 수정 없이 실행 조건을 바꾸는 방법이다.

### 4.2 export

```bash
export AGENT_HOME AGENT_PORT AGENT_UPLOAD_DIR AGENT_KEY_PATH AGENT_LOG_DIR
export MEMORY_LIMIT CPU_MAX_OCCUPY MULTI_THREAD_ENABLE
```

쉘 변수는 기본적으로 현재 쉘 안에서만 보인다. `export`를 해야 자식 프로세스인 `agent-app-leak`가 볼 수 있다.

평가 답변:

```text
환경변수를 export해야 실행되는 앱 프로세스가 그 값을 읽을 수 있다.
```

### 4.3 실행 전 검사

```bash
if [[ "$(id -u)" == "0" ]]; then
  echo "ERROR: agent-app-leak must be run as a non-root user."
  exit 1
fi
```

root 실행을 막는다.

```bash
if [[ ! -x "$APP_PATH" ]]; then
  echo "ERROR: app is not executable. Run: ./scripts/prepare.sh"
  exit 1
fi
```

실행 파일 권한이 없으면 `prepare.sh`를 먼저 실행하라고 알려준다.

### 4.4 로그 파일명 만들기

```bash
run_id="$(date '+%Y%m%d_%H%M%S')"
stdout_log="$AGENT_LOG_DIR/run_${run_id}.log"
```

예:

```text
evidence/logs/run_20260522_190141.log
```

timestamp를 붙이면 여러 번 실행해도 로그가 덮어써지지 않는다.

### 4.5 앱 실행과 로그 저장

```bash
exec "$APP_PATH" 2>&1 | tee "$stdout_log"
```

앱의 표준 출력과 에러 출력을 합쳐서 화면과 파일에 동시에 남긴다.

이 로그가 OOM, CPU, Deadlock 리포트의 핵심 증거가 된다.

---

## 5. monitor.sh

`monitor.sh`는 이번 미션의 핵심 관제 도구다. 일정 간격으로 CPU, MEM, RSS, VSZ, 스레드 수를 기록한다.

실행 예:

```bash
./scripts/monitor.sh agent-app-leak oom_before 2
```

인자:

| 위치 | 예시 | 의미 |
|---|---|---|
| `$1` | `agent-app-leak` | 찾을 프로세스 이름 |
| `$2` | `oom_before` | 결과 파일 prefix |
| `$3` | `2` | 관제 주기 초 |

결과 파일:

```text
evidence/monitor/oom_before_YYYYMMDD_HHMMSS.log
evidence/monitor/oom_before_YYYYMMDD_HHMMSS.csv
```

### 5.1 왜 monitor를 먼저 켜는가

OOM 조건은 매우 빨리 종료된다.

```text
터미널 B: monitor.sh 먼저 실행
터미널 A: run_agent.sh 나중 실행
```

이 순서를 지키지 않으면 PID를 못 잡고 관제 로그가 비어 있을 수 있다.

### 5.2 target, case_name, interval

```bash
target="${1:-agent-app-leak}"
case_name="${2:-manual}"
interval="${3:-2}"
```

인자가 없으면 기본값을 쓴다.

```bash
./scripts/monitor.sh
```

위처럼 실행하면 내부적으로는 다음과 같다.

```text
target=agent-app-leak
case_name=manual
interval=2
```

### 5.3 root PID 찾기

```bash
find_root_pid() {
  pgrep -x "$target" | head -n 1 || true
}
```

`pgrep -x "$target"`는 이름이 정확히 같은 프로세스를 찾는다.

`head -n 1`은 여러 PID가 나올 때 첫 번째 PID를 고른다.

`|| true`는 프로세스를 못 찾더라도 스크립트 전체가 바로 죽지 않게 한다. `set -e`가 켜져 있으므로, 실패 가능성이 있는 검색 명령에는 이렇게 완충 장치를 둔다.

### 5.4 자식 PID 찾기

```bash
child_pids_of() {
  local parent="$1"
  pgrep -P "$parent" || true
}
```

`pgrep -P`는 특정 부모 PID의 자식 프로세스를 찾는다.

이번 앱은 부모 프로세스와 자식 프로세스로 나뉜다. 처음 부모 PID만 봤을 때는 RSS 증가가 잘 보이지 않았다. 실제 작업은 자식 프로세스에서 일어날 수 있기 때문이다.

### 5.5 PID_FAMILY 만들기

```bash
pid_family_of() {
  local root="$1"
  printf '%s\n' "$root"
  child_pids_of "$root"
}
```

부모 PID와 자식 PID를 합쳐 하나의 관제 대상으로 만든다.

예:

```text
ROOT_PID:2752
PID_FAMILY:"2752 2754"
```

평가 답변:

```text
운영 관제에서 PID 하나만 보면 실제 작업 자식 프로세스를 놓칠 수 있다.
프로세스 트리 또는 PID family를 함께 확인해야 한다.
```

### 5.6 30초 동안 프로세스 기다리기

```bash
deadline=$((SECONDS + 30))
root_pid=""
while [[ "$SECONDS" -lt "$deadline" ]]; do
  root_pid="$(find_root_pid)"
  if [[ -n "$root_pid" ]]; then
    break
  fi
  sleep 1
done
```

monitor를 먼저 켜면 아직 앱이 실행되지 않았을 수 있다. 그래서 최대 30초 동안 기다린다.

### 5.7 CSV 헤더

```bash
echo "time,root_pid,pid_family,cpu_percent,mem_percent,rss_kb,vsz_kb,threads,elapsed" > "$csv_file"
```

CSV는 표 계산 프로그램이나 그래프 도구에서 보기 좋다.

로그 파일은 사람이 읽기 좋고, CSV는 데이터를 가공하기 좋다.

### 5.8 프로세스 생존 확인

```bash
while kill -0 "$root_pid" 2>/dev/null; do
```

`kill -0`은 실제로 프로세스를 죽이지 않는다. PID가 살아 있는지만 확인한다.

뜻:

```text
root_pid가 살아 있는 동안 계속 관제한다.
```

### 5.9 ps로 자원 사용량 수집

```bash
ps -p "$pid_csv" -o %cpu=,%mem=,rss=,vsz=,nlwp=,etime=
```

| 필드 | 의미 |
|---|---|
| `%cpu` | CPU 사용률 |
| `%mem` | 메모리 사용률 |
| `rss` | 실제 물리 메모리 사용량 KB |
| `vsz` | 가상 메모리 크기 KB |
| `nlwp` | 스레드 수 |
| `etime` | 실행 경과 시간 |

`pid_csv`는 PID 목록을 쉼표로 연결한 값이다.

```text
2752,2754
```

`ps -p`는 쉼표로 여러 PID를 받을 수 있다.

### 5.10 awk로 합산

```bash
awk '
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
'
```

부모와 자식 프로세스가 있으면 두 줄이 나온다. `awk`는 그 값을 더한다.

```text
부모 RSS + 자식 RSS = 앱 전체 RSS
부모 CPU + 자식 CPU = 앱 전체 CPU
부모 스레드 수 + 자식 스레드 수 = 전체 스레드 수
```

### 5.11 로그 한 줄 읽기

예:

```text
[2026-05-22 19:01:48] PROCESS:agent-app-leak ROOT_PID:2752 PID_FAMILY:"2752 2754" CPU:3.4% MEM:0.4% RSS:75040KB VSZ:86804KB THR:2 ELAPSED:00:06
```

해석:

```text
19:01:48에 agent-app-leak을 관찰했다.
부모 PID는 2752다.
함께 본 PID는 2752와 2754다.
전체 CPU는 3.4%다.
전체 RSS는 75040KB다.
스레드 수 합은 2개다.
프로세스 실행 후 6초가 지났다.
```

### 5.12 OOM에서 monitor.sh를 읽는 법

봐야 할 것:

```text
RSS가 시간에 따라 증가하는가?
앱 로그의 Heap 증가와 같은 흐름인가?
MemoryGuard 종료 시점과 맞는가?
```

이번 evidence:

```text
RSS: 23832KB -> 49436KB -> 75040KB
Heap: 25MB -> 50MB -> 75MB
Memory limit exceeded (75MB >= 64MB)
```

### 5.13 CPU에서 monitor.sh를 읽는 법

봐야 할 것:

```text
앱 내부 CpuWorker Current Load가 상승하는가?
CPU Threshold Violated 로그가 있는가?
CPU_MAX_OCCUPY 변경 후 cooldown 패턴이 보이는가?
```

주의:

```text
앱 내부 Current Load와 ps의 %CPU는 완전히 같은 숫자가 아닐 수 있다.
측정 주기와 기준이 다르기 때문이다.
```

### 5.14 Deadlock에서 monitor.sh를 읽는 법

Deadlock은 CPU가 높게 튀는 장애가 아니다. 오히려 CPU가 낮고 RSS도 멈춘 것처럼 보인다.

봐야 할 것:

```text
PID가 계속 살아 있는가?
CPU/RSS가 긴 시간 거의 변하지 않는가?
로그가 WAITING/BLOCKED 이후 진행되지 않는가?
snapshot에서 스레드가 sleeping 상태인가?
```

이번 evidence:

```text
PID_FAMILY:"4975 4977"
CPU: 0.6% -> 0.4% -> 0.2%
RSS: 23864KB 근처에서 정체
THR: 4
마지막 앱 로그: WAITING / BLOCKED
```

---

## 6. snapshot.sh

`snapshot.sh`는 특정 순간의 프로세스 상태를 한 파일에 저장한다. 시간별 변화는 `monitor.sh`가 맡고, 순간 증거는 `snapshot.sh`가 맡는다.

실행 예:

```bash
./scripts/snapshot.sh deadlock_retry_waiting_1
```

저장 위치:

```text
evidence/snapshots/deadlock_retry_waiting_1_YYYYMMDD_HHMMSS.txt
```

### 6.1 왜 snapshot이 필요한가

Deadlock은 프로세스가 종료되지 않는다. 그래서 “프로세스가 살아 있는데 멈춰 있다”는 증거가 필요하다.

`snapshot.sh`는 다음 정보를 저장한다.

```text
현재 시간
실험 관련 환경변수
ps -ef 결과
PID_FAMILY
ps 결과
ps -L 결과
top 결과
top -H 결과
```

### 6.2 ps -ef

```bash
ps -ef | grep "$target" | grep -v grep || true
```

전체 프로세스 목록에서 대상 이름을 찾는다.

`grep -v grep`은 `grep agent-app-leak` 명령 자기 자신이 결과에 섞이지 않게 빼는 것이다.

### 6.3 ps

```bash
ps -p "$pid_csv" -o pid,ppid,user,stat,pcpu,pmem,rss,vsz,nlwp,etime,cmd
```

프로세스 단위 상태를 보여준다.

| 필드 | 의미 |
|---|---|
| `pid` | 프로세스 ID |
| `ppid` | 부모 프로세스 ID |
| `stat` | 프로세스 상태 |
| `pcpu` | CPU 사용률 |
| `pmem` | 메모리 사용률 |
| `rss` | 실제 메모리 KB |
| `nlwp` | 스레드 수 |
| `etime` | 실행 경과 시간 |
| `cmd` | 실행 명령 |

### 6.4 ps -L

```bash
ps -L -p "$pid_csv" -o pid,tid,stat,pcpu,pmem,etime,comm
```

`-L`은 스레드를 보여준다.

| 필드 | 의미 |
|---|---|
| `PID` | 프로세스 ID |
| `TID` | 스레드 ID |
| `STAT` | 스레드 상태 |
| `%CPU` | 스레드 CPU 사용률 |
| `ELAPSED` | 실행 경과 시간 |

Deadlock에서는 스레드가 존재하지만 일을 진행하지 못하는 상태를 보려면 `ps -L`이 중요하다.

### 6.5 top과 top -H

```bash
top -b -n 1 -p "$pid_csv"
top -b -H -n 1 -p "$pid_csv"
```

| 명령 | 의미 |
|---|---|
| `top -b -n 1` | 한 번만 출력하고 종료 |
| `top -p` | 특정 PID만 관찰 |
| `top -H` | 스레드 단위로 표시 |

Deadlock snapshot에서 이런 줄이 중요하다.

```text
Threads:   4 total,   0 running,   4 sleeping
```

뜻:

```text
스레드는 4개 있지만 실행 중인 스레드는 없다.
모두 대기 상태다.
```

---

## 7. 장애별 스크립트 사용 순서

### 7.1 OOM

터미널 B:

```bash
./scripts/monitor.sh agent-app-leak oom_before 2
```

터미널 A:

```bash
MEMORY_LIMIT=64 CPU_MAX_OCCUPY=100 MULTI_THREAD_ENABLE=false ./scripts/run_agent.sh
```

### 7.2 CPU

터미널 B:

```bash
./scripts/monitor.sh agent-app-leak cpu_spike 1
```

터미널 A:

```bash
MEMORY_LIMIT=512 CPU_MAX_OCCUPY=100 MULTI_THREAD_ENABLE=false ./scripts/run_agent.sh
```

### 7.3 Deadlock

터미널 B:

```bash
./scripts/monitor.sh agent-app-leak deadlock_retry 2
```

터미널 A:

```bash
MEMORY_LIMIT=512 CPU_MAX_OCCUPY=10 MULTI_THREAD_ENABLE=true ./scripts/run_agent.sh
```

터미널 C:

```bash
./scripts/snapshot.sh deadlock_retry_waiting_1
./scripts/snapshot.sh deadlock_retry_waiting_2
```

### 7.4 Deadlock 회피

터미널 B:

```bash
./scripts/monitor.sh agent-app-leak deadlock_avoid 2
```

터미널 A:

```bash
MEMORY_LIMIT=512 CPU_MAX_OCCUPY=10 MULTI_THREAD_ENABLE=false ./scripts/run_agent.sh
```

터미널 C:

```bash
./scripts/snapshot.sh deadlock_avoid_running
```

---

## 8. 평가 대비 한 줄 답변

Q. 쉘 스크립트를 왜 만들었나?

```text
같은 실험을 반복 가능하게 만들고, evidence 파일을 일정한 위치와 형식으로 남기기 위해서다.
```

Q. `run_agent.sh` 앞에 붙이는 `MEMORY_LIMIT=64`는 무엇인가?

```text
이번 실행에만 적용되는 환경변수다. 앱은 이 값을 읽어 메모리 제한을 결정한다.
```

Q. `tee`는 왜 쓰는가?

```text
앱 로그를 화면에서 보면서 동시에 파일에도 저장하기 위해서다.
```

Q. `monitor.sh`와 `snapshot.sh`의 차이는?

```text
monitor.sh는 시간에 따른 변화를 기록하고, snapshot.sh는 특정 순간의 자세한 상태를 저장한다.
```

Q. 왜 PID_FAMILY를 쓰는가?

```text
agent-app-leak이 부모와 자식 프로세스로 나뉘어 실행되기 때문에 PID 하나만 보면 실제 자원 사용량을 놓칠 수 있다.
```

Q. Deadlock에서 `top -H`가 왜 중요한가?

```text
Deadlock은 스레드 문제이므로 프로세스 전체만 보는 것보다 스레드 단위 상태를 보는 것이 중요하다.
```
