# [Bug] OOM Crash - MEMORY_LIMIT 초과로 인한 MemoryGuard 자기 종료

## 1. Description (현상 설명)

`agent-app-leak`를 `MEMORY_LIMIT=64`, `CPU_MAX_OCCUPY=100`, `MULTI_THREAD_ENABLE=false` 조건으로 실행하면 부트 시퀀스는 정상 통과하지만, 실행 후 약 8초 뒤 Heap 사용량이 증가하며 프로세스가 종료된다.

종료 직전 로그에는 `MemoryGuard`가 `Memory limit exceeded`를 감지하고 `Self-terminating process`를 수행했다는 기록이 남았다. 따라서 이번 장애는 Linux 커널의 OOM Killer가 아니라, 애플리케이션 내부 메모리 보호 정책이 설정값을 기준으로 프로세스를 종료한 현상이다.

비교 실험으로 `MEMORY_LIMIT=512`를 적용했을 때는 동일한 `MemoryGuard` 종료가 발생하지 않았고, 프로세스가 다음 단계인 `CpuWorker`까지 진행했다.

## 2. Evidence & Logs (증거 자료)

### 실행 조건

Before:

```bash
MEMORY_LIMIT=64 CPU_MAX_OCCUPY=100 MULTI_THREAD_ENABLE=false ./scripts/run_agent.sh
```

After:

```bash
MEMORY_LIMIT=512 CPU_MAX_OCCUPY=100 MULTI_THREAD_ENABLE=false ./scripts/run_agent.sh
```

### Before: monitor.sh 관제 로그

증거 파일:

```text
evidence/monitor/oom_before_20260522_190136.log
```

핵심 구간:

```text
Monitoring root PID=2752, case=oom_before, interval=2s
[2026-05-22 19:01:42] PROCESS:agent-app-leak ROOT_PID:2752 PID_FAMILY:"2752 2754" CPU:29.6% MEM:0.1% RSS:23832KB VSZ:35596KB THR:2 ELAPSED:00:00
[2026-05-22 19:01:44] PROCESS:agent-app-leak ROOT_PID:2752 PID_FAMILY:"2752 2754" CPU:7.5% MEM:0.2% RSS:49436KB VSZ:61200KB THR:2 ELAPSED:00:02
[2026-05-22 19:01:48] PROCESS:agent-app-leak ROOT_PID:2752 PID_FAMILY:"2752 2754" CPU:3.4% MEM:0.4% RSS:75040KB VSZ:86804KB THR:2 ELAPSED:00:06
Process ended or disappeared: root PID=2752
```

RSS가 `23,832KB -> 49,436KB -> 75,040KB`로 증가했다. `PID_FAMILY:"2752 2754"`로 부모와 자식 프로세스를 함께 관제했기 때문에 실제 작업 프로세스의 메모리 증가를 확인할 수 있었다.

### Before: 애플리케이션 실행 로그

증거 파일:

```text
evidence/logs/run_20260522_190141.log
```

핵심 구간:

```text
[6/6] Verifying Mission Environment       [OK]
   ... MEMORY_LIMIT=64MB, CPU_MAX_OCCUPY=100%, MULTI_THREAD_ENABLE=False
...
2026-05-22 19:01:43,694 [INFO] [MemoryWorker] Current Heap: 25MB
2026-05-22 19:01:46,734 [INFO] [MemoryWorker] Current Heap: 50MB
2026-05-22 19:01:49,772 [INFO] [MemoryWorker] Current Heap: 75MB
2026-05-22 19:01:49,773 [CRITICAL] [MemoryGuard] Memory limit exceeded (75MB >= 64MB) / (Recommend Over 256MB)
2026-05-22 19:01:49,773 [CRITICAL] [MemoryGuard] Self-terminating process 2754 to prevent system instability.
```

Heap이 `25MB -> 50MB -> 75MB`로 증가했고, `75MB >= 64MB`가 되는 순간 MemoryGuard가 자기 종료를 수행했다.

### After: MEMORY_LIMIT 상향 후 관제 로그

증거 파일:

```text
evidence/monitor/oom_after_20260522_190204.log
```

핵심 구간:

```text
Monitoring root PID=2852, case=oom_after, interval=2s
[2026-05-22 19:02:10] PROCESS:agent-app-leak ROOT_PID:2852 PID_FAMILY:"2852 2854" CPU:30.6% MEM:0.1% RSS:23736KB VSZ:35596KB THR:2 ELAPSED:00:00
[2026-05-22 19:02:20] PROCESS:agent-app-leak ROOT_PID:2852 PID_FAMILY:"2852 2854" CPU:1.4% MEM:0.1% RSS:23784KB VSZ:35596KB THR:2 ELAPSED:00:10
[2026-05-22 19:02:30] PROCESS:agent-app-leak ROOT_PID:2852 PID_FAMILY:"2852 2854" CPU:0.9% MEM:0.1% RSS:23784KB VSZ:35596KB THR:2 ELAPSED:00:20
[2026-05-22 19:02:42] PROCESS:agent-app-leak ROOT_PID:2852 PID_FAMILY:"2852 2854" CPU:1.0% MEM:0.1% RSS:23784KB VSZ:35596KB THR:2 ELAPSED:00:32
Process ended or disappeared: root PID=2852
```

`MEMORY_LIMIT=512` 조건에서는 RSS가 약 `23,736KB ~ 23,784KB` 범위에서 유지되었고, Before와 같은 MemoryGuard 종료는 발생하지 않았다. 생존 시간도 약 8초에서 약 32초로 증가했다.

### After: 애플리케이션 실행 로그

증거 파일:

```text
evidence/logs/run_20260522_190210.log
```

핵심 구간:

```text
[6/6] Verifying Mission Environment       [OK]
   ... MEMORY_LIMIT=512MB, CPU_MAX_OCCUPY=100%, MULTI_THREAD_ENABLE=False
...
2026-05-22 19:02:12,448 [INFO] [CpuWorker] Started. Maximum CPU Limit: 100%
2026-05-22 19:02:12,449 [INFO] [CpuWorker] Current Load: 5.00%
...
2026-05-22 19:02:43,485 [INFO] [CpuWorker] Current Load: 51.78%
2026-05-22 19:02:43,585 [CRITICAL] [CpuWorker] CPU Threshold Violated! (51.779999999999994%).
```

After 실행에서는 MemoryGuard 로그가 발생하지 않고 CpuWorker 단계까지 진행되었다. 최종 종료 원인은 OOM이 아니라 CPU 보호 정책이다.

## 3. Root Cause Analysis (원인 분석)

직접 원인은 `MemoryWorker`가 Heap 사용량을 계속 증가시키고, 그 값이 `MEMORY_LIMIT=64MB`를 초과한 것이다. 로그상 Heap은 `25MB`, `50MB`, `75MB`로 증가했고, `75MB >= 64MB` 조건에서 MemoryGuard가 프로세스를 종료했다.

OS 관점에서 Heap은 실행 중 동적으로 할당되는 데이터가 주로 위치하는 메모리 영역이다. Heap에 객체나 버퍼가 계속 누적되고 해제되지 않으면 RSS가 증가한다. RSS는 실제 물리 메모리에 올라온 크기이므로, 메모리 누수 또는 지속적인 메모리 보유 현상을 판단할 때 중요한 지표다.

이번 종료는 커널 OOM Killer가 아니라 애플리케이션 내부 보호 로직인 MemoryGuard에 의한 자기 종료다. 근거는 다음과 같다.

- 앱 로그에 `Memory limit exceeded (75MB >= 64MB)`가 명시되어 있다.
- 앱 로그에 `Self-terminating process 2754`가 명시되어 있다.
- `MEMORY_LIMIT=512`로 상향하자 동일한 MemoryGuard 종료가 재현되지 않았다.

## 4. Workaround & Verification (조치 및 검증)

### 조치 내용

임시 조치로 `MEMORY_LIMIT` 값을 `64MB`에서 `512MB`로 상향했다.

```bash
# Before
MEMORY_LIMIT=64 CPU_MAX_OCCUPY=100 MULTI_THREAD_ENABLE=false ./scripts/run_agent.sh

# After
MEMORY_LIMIT=512 CPU_MAX_OCCUPY=100 MULTI_THREAD_ENABLE=false ./scripts/run_agent.sh
```

### Before & After 비교

| 항목 | Before | After |
|---|---:|---:|
| `MEMORY_LIMIT` | `64MB` | `512MB` |
| 관제 대상 | `PID_FAMILY:"2752 2754"` | `PID_FAMILY:"2852 2854"` |
| RSS 변화 | `23,832KB -> 75,040KB` | 약 `23,736KB ~ 23,784KB` 유지 |
| Heap 로그 | `25MB -> 50MB -> 75MB` | MemoryGuard 종료 로그 없음 |
| MemoryGuard 발생 | 발생 | 미발생 |
| 생존 시간 | 약 `8초` | 약 `32초` |
| 최종 종료 원인 | Memory limit exceeded | CPU Threshold Violated |

### 검증 결과

`MEMORY_LIMIT=64` 조건에서는 RSS와 Heap이 증가한 뒤 MemoryGuard가 종료를 수행했다. 반면 `MEMORY_LIMIT=512` 조건에서는 동일한 MemoryGuard 종료가 발생하지 않았고, 프로세스가 다음 워크로드인 CpuWorker까지 진행했다.

따라서 `MEMORY_LIMIT` 상향은 OOM Crash를 지연 또는 회피하는 임시 조치로 유효하다. 근본적으로는 Heap에 누적되는 객체의 생명주기를 점검하고, 불필요한 참조 제거, 버퍼 크기 제한, 캐시 eviction 정책 등을 적용해야 한다.
