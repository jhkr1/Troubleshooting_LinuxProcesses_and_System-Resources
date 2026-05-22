# [Bug] Deadlock - 멀티스레드 락 순환 대기로 프로세스 무응답

## 1. Description (현상 설명)

`agent-app-leak`를 `MEMORY_LIMIT=512`, `CPU_MAX_OCCUPY=10`, `MULTI_THREAD_ENABLE=true` 조건으로 실행하면 부트 시퀀스는 정상 통과하지만, 앱이 멀티스레드 모드의 교착 위험을 경고한다.

실행 후 두 작업 스레드가 각각 다른 공유 자원을 먼저 점유한다. 이후 각 스레드가 상대 스레드가 가진 자원을 요청하면서 `WAITING`, `BLOCKED` 로그를 마지막으로 더 이상 진행하지 않는다. 이때 프로세스 PID는 살아 있지만 CPU/RSS 변화가 거의 없고, `ps -L`, `top -H`에서도 스레드들이 실행 중이 아니라 대기 상태로 남아 있다.

따라서 이번 장애는 프로세스 크래시가 아니라, 멀티스레드 락 순환 대기로 인한 Deadlock 무응답 상태로 판단한다.

## 2. Evidence & Logs (증거 자료)

### 재현 조건

실행 명령:

```bash
MEMORY_LIMIT=512 CPU_MAX_OCCUPY=10 MULTI_THREAD_ENABLE=true ./scripts/run_agent.sh
```

증거 파일:

```text
evidence/logs/run_20260522_190540.log
evidence/monitor/deadlock_retry_20260522_190536.log
evidence/snapshots/deadlock_retry_waiting_1_20260522_190602.txt
evidence/snapshots/deadlock_retry_waiting_2_20260522_190627.txt
```

### 애플리케이션 실행 로그

```text
[6/6] Verifying Mission Environment       [OK]
   ... MEMORY_LIMIT=512MB, CPU_MAX_OCCUPY=10%, MULTI_THREAD_ENABLE=True
...
 [ THREAD ] Concurrency: True             [ WARNING ]
--------------------------------------------------
 >>> SYSTEM WARNING: POTENTIAL DEADLOCK IN CONCURRENT MODE.
```

멀티스레드 경로가 활성화되었고, 애플리케이션이 Deadlock 가능성을 경고했다.

마지막 핵심 로그:

```text
2026-05-22 19:05:47,197 [INFO] [AgentWorker][Worker-Thread-1] LOCK ACQUIRED: [Shared_Memory_A]. (Holding...)
2026-05-22 19:05:47,197 [INFO] [AgentWorker][Worker-Thread-2] LOCK ACQUIRED: [Socket_Pool_B]. (Holding...)
2026-05-22 19:05:49,200 [INFO] [AgentWorker][Worker-Thread-1] Need resource [Socket_Pool_B] to finish job.
2026-05-22 19:05:49,201 [INFO] [AgentWorker][Worker-Thread-2] Need resource [Shared_Memory_A] to write logs.
2026-05-22 19:05:49,201 [INFO] [AgentWorker][Worker-Thread-1] WAITING for [Socket_Pool_B]... (Status: BLOCKED)
2026-05-22 19:05:49,202 [INFO] [AgentWorker][Worker-Thread-2] WAITING for [Shared_Memory_A]... (Status: BLOCKED)
```

로그상 `Worker-Thread-1`은 `Shared_Memory_A`를 점유한 채 `Socket_Pool_B`를 기다린다. 반대로 `Worker-Thread-2`는 `Socket_Pool_B`를 점유한 채 `Shared_Memory_A`를 기다린다. 이후 추가 진행 로그가 없으므로 락 대기 상태에서 멈춘 것으로 판단한다.

### monitor.sh 관제 로그

증거 파일:

```text
evidence/monitor/deadlock_retry_20260522_190536.log
```

핵심 구간:

```text
[2026-05-22 19:05:48] PROCESS:agent-app-leak ROOT_PID:4975 PID_FAMILY:"4975 4977" CPU:1.4% MEM:0.1% RSS:23864KB VSZ:183092KB THR:4 ELAPSED:00:08
[2026-05-22 19:05:58] PROCESS:agent-app-leak ROOT_PID:4975 PID_FAMILY:"4975 4977" CPU:0.6% MEM:0.1% RSS:23864KB VSZ:183092KB THR:4 ELAPSED:00:18
[2026-05-22 19:06:08] PROCESS:agent-app-leak ROOT_PID:4975 PID_FAMILY:"4975 4977" CPU:0.4% MEM:0.1% RSS:23864KB VSZ:183092KB THR:4 ELAPSED:00:28
[2026-05-22 19:06:20] PROCESS:agent-app-leak ROOT_PID:4975 PID_FAMILY:"4975 4977" CPU:0.2% MEM:0.1% RSS:23864KB VSZ:183092KB THR:4 ELAPSED:00:40
[2026-05-22 19:06:34] PROCESS:agent-app-leak ROOT_PID:4975 PID_FAMILY:"4975 4977" CPU:0.2% MEM:0.1% RSS:23792KB VSZ:183092KB THR:4 ELAPSED:00:54
```

PID family는 `4975 4977`로 유지되었고, 스레드 수는 `4`개로 고정되었다. RSS는 약 `23,864KB`에서 거의 변하지 않았고, CPU도 `0.2%~0.6%` 수준으로 낮아졌다. 이는 프로세스가 종료된 것이 아니라 살아 있으나 작업 진행이 멈춘 상태에 가깝다.

### ps/top 스냅샷

증거 파일:

```text
evidence/snapshots/deadlock_retry_waiting_1_20260522_190602.txt
evidence/snapshots/deadlock_retry_waiting_2_20260522_190627.txt
```

첫 번째 스냅샷:

```text
## time
Fri May 22 19:06:02 KST 2026

## pid family
ROOT_PID=4975
PID_FAMILY=4975 4977

## ps -L
    PID     TID STAT %CPU %MEM     ELAPSED COMMAND
   4975    4975 S+    0.3  0.0       00:22 agent-app-leak
   4977    4977 SNl+  0.2  0.1       00:22 agent-app-leak
   4977    5035 SNl+  0.0  0.1       00:15 agent-app-leak
   4977    5036 SNl+  0.0  0.1       00:15 agent-app-leak

## top -H
Threads:   4 total,   0 running,   4 sleeping,   0 stopped,   0 zombie
```

두 번째 스냅샷:

```text
## time
Fri May 22 19:06:27 KST 2026

## pid family
ROOT_PID=4975
PID_FAMILY=4975 4977

## ps -L
    PID     TID STAT %CPU %MEM     ELAPSED COMMAND
   4975    4975 S+    0.1  0.0       00:47 agent-app-leak
   4977    4977 SNl+  0.1  0.1       00:47 agent-app-leak
   4977    5035 SNl+  0.0  0.1       00:40 agent-app-leak
   4977    5036 SNl+  0.0  0.1       00:40 agent-app-leak

## top -H
Threads:   4 total,   0 running,   4 sleeping,   0 stopped,   0 zombie
```

두 스냅샷 사이에 약 25초가 지났지만 PID는 유지되었고, 스레드들은 계속 sleeping 상태였다. CPU 작업이 진행되는 상태라면 일부 스레드가 running으로 관측되거나 로그가 계속 진행되어야 하지만, 실제로는 대기 상태가 유지되었다.

### 회피 조건

회피 실험 명령:

```bash
MEMORY_LIMIT=512 CPU_MAX_OCCUPY=10 MULTI_THREAD_ENABLE=false ./scripts/run_agent.sh
```

`MULTI_THREAD_ENABLE=false` 조건에서는 멀티스레드 락 경로가 비활성화된다. 기대 로그는 다음과 같다.

증거 파일:

```text
evidence/logs/run_20260522_191636.log
evidence/monitor/deadlock_avoid_20260522_191632.log
evidence/snapshots/deadlock_avoid_running_20260522_191643.txt
evidence/snapshots/deadlock_avoid_running_20260522_191649.txt
```

```text
[6/6] Verifying Mission Environment       [OK]
   ... MEMORY_LIMIT=512MB, CPU_MAX_OCCUPY=10%, MULTI_THREAD_ENABLE=False
...
 [ THREAD ] Concurrency: False            [ OK ]
--------------------------------------------------
 >>> SYSTEM STATUS: STABLE. STARTING WORKLOAD MONITORING...
```

회피 조건의 애플리케이션 로그에는 `POTENTIAL DEADLOCK`, `WAITING`, `BLOCKED`가 나타나지 않았다. 대신 정상 상태에서 스케줄러 테스트와 CPU/Memory 워커가 진행되었다.

```text
2026-05-22 19:16:38,244 [INFO] [Scheduler] Task Scheduler Initialized.
2026-05-22 19:16:38,244 [INFO] [Scheduler] Registered Tasks: ['Thread-A', 'Thread-B', 'Thread-C']
2026-05-22 19:16:38,347 [INFO] [Thread-A] Preempted. Progress saved at (40%)
2026-05-22 19:16:38,502 [INFO] [Thread-B] Preempted. Progress saved at (40%)
2026-05-22 19:16:38,656 [INFO] [Thread-C] Preempted. Progress saved at (40%)
2026-05-22 19:16:39,325 [INFO] [Scheduler] All tasks completed.
```

회피 조건 관제 로그:

```text
[2026-05-22 19:16:36] PROCESS:agent-app-leak ROOT_PID:5550 PID_FAMILY:"5550 5552" CPU:70.8% MEM:0.1% RSS:23772KB VSZ:35596KB THR:2 ELAPSED:00:00
[2026-05-22 19:16:44] PROCESS:agent-app-leak ROOT_PID:5550 PID_FAMILY:"5550 5552" CPU:3.0% MEM:0.4% RSS:75172KB VSZ:234300KB THR:4 ELAPSED:00:08
[2026-05-22 19:16:52] PROCESS:agent-app-leak ROOT_PID:5550 PID_FAMILY:"5550 5552" CPU:2.3% MEM:0.9% RSS:151984KB VSZ:311112KB THR:4 ELAPSED:00:16
```

회피 조건에서는 메모리 워커가 계속 진행되며 RSS가 증가하고, 정상 스케줄링 로그도 계속 남았다. 이는 재현 조건처럼 특정 락 대기 지점에서 로그가 멈춘 상태와 다르다.

## 3. Root Cause Analysis (원인 분석)

Deadlock은 여러 스레드가 서로 상대방이 점유한 자원을 기다리며 더 이상 진행하지 못하는 상태다. 이번 실험에서는 두 스레드가 공유 자원을 반대 순서로 획득하면서 순환 대기가 만들어졌다.

실제 대기 관계:

```text
Worker-Thread-1
1. Shared_Memory_A 획득
2. Socket_Pool_B 필요
3. Socket_Pool_B는 Worker-Thread-2가 보유 중이라 BLOCKED

Worker-Thread-2
1. Socket_Pool_B 획득
2. Shared_Memory_A 필요
3. Shared_Memory_A는 Worker-Thread-1이 보유 중이라 BLOCKED
```

Deadlock 4대 조건과의 연결:

| 조건 | 이번 실험의 근거 |
|---|---|
| 상호 배제 | `Shared_Memory_A`, `Socket_Pool_B`는 동시에 여러 스레드가 사용할 수 없는 락 자원이다. |
| 점유 대기 | 각 스레드가 이미 하나의 자원을 잡은 채 다른 자원을 기다린다. |
| 비선점 | 한 스레드가 가진 락을 다른 스레드가 강제로 빼앗지 못한다. |
| 순환 대기 | Thread-1은 Thread-2의 자원을, Thread-2는 Thread-1의 자원을 기다린다. |

OS 관점에서 이 프로세스는 죽은 프로세스가 아니다. PID가 살아 있고 스레드도 존재한다. 그러나 스레드들이 락 획득을 기다리는 상태에서 실행 가능한 작업을 만들지 못하므로 CPU 사용률은 낮고 로그도 더 이상 진행되지 않는다.

## 4. Workaround & Verification (조치 및 검증)

### 임시 조치

멀티스레드 경로에서 교착이 발생하므로 임시 조치로 `MULTI_THREAD_ENABLE=false`를 적용한다.

```bash
# 장애 재현 조건
MEMORY_LIMIT=512 CPU_MAX_OCCUPY=10 MULTI_THREAD_ENABLE=true ./scripts/run_agent.sh

# 회피 조건
MEMORY_LIMIT=512 CPU_MAX_OCCUPY=10 MULTI_THREAD_ENABLE=false ./scripts/run_agent.sh
```

### Before & After 비교

| 항목 | Before | After |
|---|---|---|
| `MULTI_THREAD_ENABLE` | `true` | `false` |
| Thread 상태 표시 | `Concurrency: True [WARNING]` | `Concurrency: False [OK]` |
| Deadlock 경고 | `POTENTIAL DEADLOCK IN CONCURRENT MODE` | 없음 |
| 마지막 로그 | `WAITING`, `BLOCKED` | 스케줄러, MemoryWorker, CpuWorker 진행 |
| PID 상태 | 살아 있으나 진행 없음 | Deadlock 경로 회피 |
| 스레드 상태 | `4 sleeping`, 로그 정지 | 순환 락 대기 없음 |
| 증거 파일 | `deadlock_retry_*` | `deadlock_avoid_*` |

### 근본 해결 제안

임시 조치로 멀티스레드를 끄면 Deadlock은 피할 수 있지만 처리량이 낮아질 수 있다. 근본 해결은 코드 수준에서 락 획득 정책을 바꾸는 것이다.

- 모든 스레드가 항상 같은 순서로 락을 획득한다. 예: 항상 `Shared_Memory_A -> Socket_Pool_B`.
- 두 번째 락 획득에 timeout 또는 try-lock을 적용하고 실패하면 첫 번째 락을 해제한 뒤 재시도한다.
- 긴 작업 중 락을 오래 들고 있지 않도록 critical section을 줄인다.
- 공유 자원 접근을 큐나 단일 writer 구조로 바꿔 순환 대기 가능성을 제거한다.
