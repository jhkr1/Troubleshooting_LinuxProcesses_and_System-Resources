# [Bug] CPU Latency - CpuWorker 부하 상승 후 CPU Threshold 보호 종료

## 1. Description (현상 설명)

`agent-app-leak`를 `MEMORY_LIMIT=512`, `CPU_MAX_OCCUPY=100`, `MULTI_THREAD_ENABLE=false` 조건으로 실행하면 부트 시퀀스는 정상 통과하지만, `CpuWorker` 단계에서 앱 내부 CPU Load가 점진적으로 상승한 뒤 `CPU Threshold Violated` 로그와 함께 프로세스가 종료된다.

이번 장애는 메모리 부족이나 데드락이 아니라, 애플리케이션 내부 CPU 부하 작업이 보호 임계 구간까지 상승하고 CPU 보호 정책이 종료를 수행한 현상으로 판단된다.

비교 실험으로 `CPU_MAX_OCCUPY=10`을 적용했을 때는 CPU 부하가 10% 피크에 도달하면 cooldown을 수행하며 즉시 종료되지 않았다. 즉, `CPU_MAX_OCCUPY` 값을 낮추면 앱이 CPU 부하를 제한하고 안정화 루프로 들어가는 것을 확인했다.

## 2. Evidence & Logs (증거 자료)

### 장애 재현 조건: CPU_MAX_OCCUPY=100

실행 명령:

```bash
MEMORY_LIMIT=512 CPU_MAX_OCCUPY=100 MULTI_THREAD_ENABLE=false ./scripts/run_agent.sh
```

증거 파일:

```text
evidence/logs/run_20260522_190300.log
evidence/monitor/cpu_spike_20260522_190255.log
```

애플리케이션 실행 로그 핵심 구간:

```text
[6/6] Verifying Mission Environment       [OK]
   ... MEMORY_LIMIT=512MB, CPU_MAX_OCCUPY=100%, MULTI_THREAD_ENABLE=False
...
2026-05-22 19:03:02,636 [INFO] [CpuWorker] Started. Maximum CPU Limit: 100%
2026-05-22 19:03:02,636 [INFO] [CpuWorker] Current Load: 5.00%
2026-05-22 19:03:05,740 [INFO] [CpuWorker] Current Load: 11.00%
2026-05-22 19:03:11,946 [INFO] [CpuWorker] Current Load: 19.60%
2026-05-22 19:03:18,156 [INFO] [CpuWorker] Current Load: 34.47%
2026-05-22 19:03:24,365 [INFO] [CpuWorker] Current Load: 49.33%
2026-05-22 19:03:27,470 [INFO] [CpuWorker] Current Load: 57.37%
2026-05-22 19:03:27,572 [CRITICAL] [CpuWorker] CPU Threshold Violated! (57.37%).
```

관제 로그 핵심 구간:

```text
Monitoring root PID=3116, case=cpu_spike, interval=1s
[2026-05-22 19:03:00] PROCESS:agent-app-leak ROOT_PID:3116 PID_FAMILY:"3116" CPU:80.0% MEM:0.0% RSS:2056KB VSZ:2900KB THR:1 ELAPSED:00:00
[2026-05-22 19:03:01] PROCESS:agent-app-leak ROOT_PID:3116 PID_FAMILY:"3116 3136" CPU:13.6% MEM:0.1% RSS:23820KB VSZ:35596KB THR:2 ELAPSED:00:00
[2026-05-22 19:03:08] PROCESS:agent-app-leak ROOT_PID:3116 PID_FAMILY:"3116 3136" CPU:1.8% MEM:0.1% RSS:23868KB VSZ:35596KB THR:2 ELAPSED:00:08
[2026-05-22 19:03:18] PROCESS:agent-app-leak ROOT_PID:3116 PID_FAMILY:"3116 3136" CPU:1.3% MEM:0.1% RSS:23868KB VSZ:35596KB THR:2 ELAPSED:00:18
[2026-05-22 19:03:26] PROCESS:agent-app-leak ROOT_PID:3116 PID_FAMILY:"3116 3136" CPU:1.3% MEM:0.1% RSS:23868KB VSZ:35596KB THR:2 ELAPSED:00:26
Process ended or disappeared: root PID=3116
```

### CPU 지표 해석: Current Load와 monitor CPU의 차이

이 리포트에는 CPU처럼 보이는 숫자가 두 종류 나온다.

| 위치 | 예시 | 의미 |
|---|---|---|
| 애플리케이션 로그 | `[CpuWorker] Current Load: 57.37%` | 앱 내부 `CpuWorker`가 계산한 부하 수준이다. `CPU_MAX_OCCUPY`와 보호 정책 판단에 쓰이는 애플리케이션 내부 지표다. |
| 관제 로그 | `CPU:1.3%` | Linux `ps`가 본 프로세스 패밀리의 CPU 사용률이다. `monitor.sh`가 부모/자식 PID의 `%CPU`를 합산해 기록한다. |

두 값은 같은 숫자로 맞아야 하는 지표가 아니다.

`Current Load`는 앱이 자신의 워크로드 진행 상태와 보호 임계치를 판단하기 위해 출력하는 내부 값이다. 그래서 `5.00% -> 57.37%`처럼 CpuWorker의 부하 상승 흐름을 직접 보여준다. 반면 `monitor.sh`의 `CPU:%`는 운영체제가 관찰한 프로세스의 CPU time 사용 비율이다. 이 값은 `ps` 기준으로 계산되며, 측정 시점, 프로세스 실행 시간, 부모/자식 PID 합산 방식, 스케줄러의 CPU 배분에 영향을 받는다.

따라서 이번 CPU 장애의 핵심 증거는 다음처럼 해석한다.

```text
앱 내부 로그:
CpuWorker가 스스로 계산한 Current Load가 57.37%까지 상승했고,
그 결과 CPU Threshold Violated 보호 종료가 발생했다.

관제 로그:
해당 시점에 agent-app-leak PID_FAMILY가 실제로 살아 있었고,
CPU/MEM/RSS/스레드 수가 같은 실행 흐름 안에서 관측되었다.
```

즉, 앱 내부 로그는 “왜 종료했는가”를 설명하는 직접 증거이고, 관제 로그는 “그 종료가 특정 프로세스 실행 중에 발생했다”는 시스템 관찰 증거다.

### 완화 조건: CPU_MAX_OCCUPY=10

실행 명령:

```bash
MEMORY_LIMIT=512 CPU_MAX_OCCUPY=10 MULTI_THREAD_ENABLE=false ./scripts/run_agent.sh
```

증거 파일:

```text
evidence/logs/run_20260522_190338.log
evidence/monitor/cpu_limited_20260522_190334.log
evidence/snapshots/cpu_limited_running_20260522_190414.txt
evidence/snapshots/cpu_limited_running_20260522_190434.txt
```

애플리케이션 실행 로그 핵심 구간:

```text
[6/6] Verifying Mission Environment       [OK]
   ... MEMORY_LIMIT=512MB, CPU_MAX_OCCUPY=10%, MULTI_THREAD_ENABLE=False
...
2026-05-22 19:03:41,967 [INFO] [CpuWorker] Started. Maximum CPU Limit: 10%
2026-05-22 19:03:41,968 [INFO] [CpuWorker] Current Load: 5.00%
2026-05-22 19:03:44,070 [INFO] [CpuWorker] Peak reached (10.00%). Starting cooldown...
2026-05-22 19:03:45,072 [INFO] [CpuWorker] Current Load: 10.00%
2026-05-22 19:03:53,385 [INFO] [CpuWorker] Cooldown complete (5.00%). Resuming load increase...
...
2026-05-22 19:04:42,759 [WARNING] [MemoryWorker] Memory Usage Reached Limit (525MB). Starting cleanup...
2026-05-22 19:04:42,768 [INFO] [System] Memory Cache Flushed. Process Stabilized.
```

관제 로그 핵심 구간:

```text
[2026-05-22 19:04:26] PROCESS:agent-app-leak ROOT_PID:3510 PID_FAMILY:"3510 3512" CPU:1.7% MEM:2.4% RSS:408180KB VSZ:567152KB THR:4 ELAPSED:00:47
[2026-05-22 19:04:40] PROCESS:agent-app-leak ROOT_PID:3510 PID_FAMILY:"3510 3512" CPU:1.7% MEM:3.2% RSS:536200KB VSZ:695172KB THR:4 ELAPSED:01:01
[2026-05-22 19:04:43] PROCESS:agent-app-leak ROOT_PID:3510 PID_FAMILY:"3510 3512" CPU:1.7% MEM:0.1% RSS:24120KB VSZ:183092KB THR:4 ELAPSED:01:04
[2026-05-22 19:05:12] PROCESS:agent-app-leak ROOT_PID:3510 PID_FAMILY:"3510 3512" CPU:1.4% MEM:1.5% RSS:254380KB VSZ:445236KB THR:4 ELAPSED:01:33
[2026-05-22 19:05:24] PROCESS:agent-app-leak ROOT_PID:3510 PID_FAMILY:"3510 3512" CPU:1.4% MEM:2.1% RSS:356788KB VSZ:576308KB THR:4 ELAPSED:01:46
```

`CPU_MAX_OCCUPY=10` 조건에서는 `CpuWorker`가 10% 피크에 도달할 때마다 cooldown을 수행했다. 관제에서도 프로세스가 최소 1분 40초 이상 유지되며 즉시 종료되지 않았다.

### ps/top 스냅샷

증거 파일:

```text
evidence/snapshots/cpu_limited_running_20260522_190414.txt
evidence/snapshots/cpu_limited_running_20260522_190434.txt
```

두 스냅샷은 `CPU_MAX_OCCUPY=10` 완화 조건에서 실행 중인 프로세스 상태를 저장한 자료다. CPU 보호 종료가 즉시 발생하지 않고, 대상 프로세스가 계속 살아 있는 상태를 보조적으로 확인한다.

## 3. Root Cause Analysis (원인 분석)

직접 원인은 `CpuWorker`가 CPU 부하를 점진적으로 증가시키는 과정에서 내부 CPU Threshold에 도달한 것이다. `CPU_MAX_OCCUPY=100` 조건에서는 부하 상승을 강하게 제한하지 않았고, 앱 내부 로그 기준 `Current Load`가 `5.00%`에서 `57.37%`까지 상승했다. 이후 `CPU Threshold Violated!`가 기록되며 프로세스가 종료되었다.

OS 관점에서 CPU 과점유는 프로세스가 CPU time을 지속적으로 소비하는 상태다. CPU-bound 작업이 길게 지속되면 같은 CPU를 공유하는 다른 프로세스나 스레드가 실행 기회를 얻기 위해 더 오래 대기할 수 있고, 서비스 관점에서는 응답 지연으로 보일 수 있다.

이번 실험에서는 시스템 전체 CPU가 계속 높게 유지된 것은 아니지만, 앱 내부 `CpuWorker` 로그가 보호 정책 관점의 부하 상승을 명확하게 보여준다. 또한 `monitor.sh`는 `PID_FAMILY` 단위로 대상 프로세스 패밀리를 추적하여, CPU 관련 이벤트가 특정 앱 실행과 연결되어 있음을 확인했다.

`CPU_MAX_OCCUPY=10` 조건에서는 부하가 10%에 도달하면 `Peak reached`, `Starting cooldown`, `Cooldown complete` 로그가 반복되었다. 이는 임계값을 낮추면 앱이 CPU 부하를 스스로 제한하고 안정화 루프로 들어간다는 의미다.

## 4. Workaround & Verification (조치 및 검증)

### 조치 내용

임시 조치로 `CPU_MAX_OCCUPY`를 `100`에서 `10`으로 낮춰 CpuWorker가 더 이른 시점에 cooldown하도록 제한했다.

```bash
# 장애 재현 조건
MEMORY_LIMIT=512 CPU_MAX_OCCUPY=100 MULTI_THREAD_ENABLE=false ./scripts/run_agent.sh

# 완화 조건
MEMORY_LIMIT=512 CPU_MAX_OCCUPY=10 MULTI_THREAD_ENABLE=false ./scripts/run_agent.sh
```

### Before & After 비교

| 항목 | 장애 재현 조건 | 완화 조건 |
|---|---:|---:|
| `CPU_MAX_OCCUPY` | `100%` | `10%` |
| 관제 대상 | `PID_FAMILY:"3116 3136"` | `PID_FAMILY:"3510 3512"` |
| 앱 내부 CPU Load | `5.00% -> 57.37%` | `5.00% -> 10.00% -> cooldown` |
| CPU 보호 로그 | `CPU Threshold Violated!` | `Peak reached`, `Starting cooldown`, `Cooldown complete` |
| 종료 여부 | Threshold 이후 종료 | 관찰 구간 동안 즉시 종료 없음 |
| 생존 시간 | 약 `27초` | 최소 `1분 46초` 관찰 |

### 검증 결과

`CPU_MAX_OCCUPY=100` 조건에서는 CpuWorker 부하가 `57.37%`까지 상승한 뒤 `CPU Threshold Violated!`가 발생하며 프로세스가 종료되었다. 반면 `CPU_MAX_OCCUPY=10` 조건에서는 10% 피크에 도달하면 cooldown이 반복되어 급격한 CPU 상승이 제한되었다.

따라서 CPU Spike 장애에 대한 임시 조치로 `CPU_MAX_OCCUPY`를 낮추는 방식은 유효하다. 근본적으로는 CPU-bound 작업의 반복 횟수와 실행 시간을 제한하고, 긴 계산 작업은 작업 큐, rate limit, backoff, 타임아웃, 비동기 처리 또는 별도 워커 프로세스로 분리하는 개선이 필요하다.
