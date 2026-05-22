# Linux Process Troubleshooting Lab

`agent-app-leak` 장애 분석 실습 기록이다. 이 저장소의 목표는 단순히 프로그램을 실행해 보는 것이 아니라, Linux 위에서 프로세스가 어떻게 메모리와 CPU를 쓰고, 스레드가 어떻게 대기 상태에 빠지는지 관찰한 뒤 GitHub Issue 형식의 기술 리포트로 남기는 것이다.

이 문서는 한 권의 작은 실습서처럼 읽히도록 구성했다. 위에서 아래로 따라가면 OrbStack Ubuntu에서 환경을 준비하고, OOM Crash, CPU Spike, Deadlock을 재현하고, 왜 그런 현상이 일어났는지 설명할 수 있다.

---

## 목차

1. 이 실습에서 배워야 할 것
2. Linux 프로세스를 보는 기본 눈
3. OrbStack Ubuntu 실험 환경 만들기
4. 스크립트라는 실험 도구
5. 공통 실험 규칙
6. OOM Crash: 메모리가 차오르는 장면
7. CPU Spike와 운영체제 스케줄링
8. Deadlock: 살아 있지만 앞으로 가지 못하는 프로세스
9. 미션을 진행하면서 개인적으로 궁금했던 것들

---

## 1. 이 실습에서 배워야 할 것

운영 장애를 처음 마주하면 마음이 급해진다. 프로세스가 죽었거나, CPU가 튀었거나, 로그가 멈췄을 때 가장 쉬운 행동은 재시작이다. 하지만 재시작은 증거를 지운다. 증거가 사라지면 원인도 사라지고, 같은 장애는 다시 돌아온다.

이번 미션에서 배워야 하는 태도는 이것이다.

```text
1. 먼저 관찰한다.
2. 로그와 시스템 도구로 증거를 남긴다.
3. 증거를 기준으로 원인을 추론한다.
4. 환경변수를 바꿔 Before & After를 비교한다.
5. 동료가 이해할 수 있는 이슈 리포트로 정리한다.
```

이번 실습의 세 장애는 서로 다르지만 한 가지 공통점이 있다. 모두 운영체제 위에서 실행 중인 프로세스의 자원 사용 문제다.

| 장애 | 핵심 자원 | 관찰 포인트 |
|---|---|---|
| OOM Crash | Memory | RSS/Heap 증가, MemoryGuard 종료 |
| CPU Spike | CPU time | CpuWorker 부하 상승, CPU Threshold |
| Deadlock | Thread/Lock | PID 생존, 로그 정지, 스레드 대기 |

---

## 2. Linux 프로세스를 보는 기본 눈

### 2.1 프로그램과 프로세스

프로그램은 디스크에 있는 실행 파일이다. `agent-app-leak` 파일 자체는 아직 실행 중인 것이 아니다.

프로세스는 실행 중인 프로그램이다. Linux가 실행 파일을 메모리에 올리고 PID를 부여하면 그때부터 프로세스가 된다.

```text
agent-app-leak 파일: 프로그램
PID 2752 agent-app-leak: 프로세스
```

프로세스는 독립된 주소 공간을 가진다. 주소 공간에는 코드, 데이터, Heap, Stack 같은 영역이 있다.

### 2.2 스레드

스레드는 같은 프로세스 안에서 실행되는 작업 흐름이다. 스레드는 프로세스의 메모리를 공유한다.

```text
프로세스: 독립된 실행 공간
스레드: 그 공간 안에서 움직이는 실행 흐름
```

스레드는 메모리를 공유하므로 빠르지만 조심해야 한다. 같은 자원을 동시에 만지면 경쟁 상태가 생기고, 락을 잘못 잡으면 Deadlock이 생긴다.

### 2.3 RSS와 VSZ

`monitor.sh`는 RSS와 VSZ를 남긴다.

| 지표 | 뜻 | 이번 미션에서 쓰는 법 |
|---|---|---|
| RSS | 실제 물리 메모리에 올라온 크기 | 메모리 증가 확인 |
| VSZ | 프로세스가 확보한 가상 메모리 크기 | 참고 지표 |

OOM 분석에서는 RSS가 중요하다. 실제 물리 메모리를 얼마나 차지하는지 보여주기 때문이다.

### 2.4 CPU time과 스케줄링

CPU는 한 순간에 제한된 수의 작업만 실행할 수 있다. 실행하고 싶은 프로세스와 스레드는 많고 CPU는 한정되어 있으므로, 운영체제는 누구에게 CPU를 줄지 계속 결정한다. 이 결정 과정을 스케줄링이라고 한다.

이번 로그에는 스케줄링을 추론할 수 있는 장면이 나온다.

```text
Thread-A Task Started... (20%)
Thread-A Calculating... (40%)
Thread-A Preempted. Progress saved at (40%)
Thread-B Task Started... (20%)
Thread-B Calculating... (40%)
Thread-B Preempted. Progress saved at (40%)
Thread-C Task Started... (20%)
...
Thread-A Resumed...
```

하나의 스레드가 끝까지 실행되지 않고 A, B, C가 번갈아 진행된다. 이 패턴은 먼저 온 작업을 끝까지 처리하는 FCFS보다는, 각 작업에 짧은 실행 기회를 나눠 주는 Round-Robin 방식에 가깝다.

### 2.5 락과 Deadlock

락은 공유 자원을 한 번에 하나의 스레드만 쓰게 만드는 장치다. 락 자체는 나쁜 것이 아니다. 문제는 여러 락을 서로 다른 순서로 잡을 때 생긴다.

```text
Thread-1: A를 잡고 B를 기다림
Thread-2: B를 잡고 A를 기다림
```

이 상태에서는 누구도 앞으로 갈 수 없다. 이것이 Deadlock이다.

Deadlock 4대 조건:

| 조건 | 뜻 |
|---|---|
| 상호 배제 | 한 자원을 동시에 여러 스레드가 쓸 수 없음 |
| 점유 대기 | 이미 잡은 자원을 놓지 않고 다른 자원을 기다림 |
| 비선점 | 남이 잡은 자원을 강제로 빼앗을 수 없음 |
| 순환 대기 | 서로가 서로의 자원을 기다리는 고리 형성 |

---

## 3. OrbStack Ubuntu 실험 환경 만들기

이 바이너리는 Linux 실행 파일이다. macOS 터미널에서 직접 실행하지 않는다. OrbStack Ubuntu 안에서 실행한다.

macOS 터미널:

```bash
orb create ubuntu:24.04 ubuntu24
orb -m ubuntu24
```

Ubuntu 안에서 확인:

```bash
whoami
id -u
pwd
cat /etc/os-release
uname -m
```

프로젝트 폴더로 이동:

```bash
cd /mnt/mac/Users/wlgjs060614351/Desktop/Troubleshooting_LinuxProcesses_and_System-Resources
ls -la
```

터미널을 새로 열 때마다 먼저 `cd`부터 한다. `~`에서 `./scripts/prepare.sh`를 실행하면 실패한다. 스크립트는 프로젝트 폴더 안에 있다.

필수 패키지 설치:

```bash
sudo apt update
sudo apt install -y procps psmisc iproute2 unzip file
```

패키지의 의미:

| 패키지/명령 | 쓰는 이유 |
|---|---|
| `procps` | `ps`, `top` 사용 |
| `psmisc` | 프로세스 관련 도구 보강 |
| `iproute2` | `ss`로 포트 확인 |
| `unzip` | 제공 zip 압축 해제 |
| `file` | 실행 파일 형식 확인 |

---

## 4. 스크립트라는 실험 도구

이 저장소에는 꼭 필요한 스크립트만 남겼다.

| 파일 | 역할 |
|---|---|
| `scripts/prepare.sh` | 실험 전 디렉터리, 키 파일, 실행 권한 준비 |
| `scripts/run_agent.sh` | 환경변수를 설정하고 앱 실행 로그 저장 |
| `scripts/monitor.sh` | 시간별 CPU/MEM/RSS/스레드 수 기록 |
| `scripts/snapshot.sh` | 특정 순간의 `ps`, `ps -L`, `top`, `top -H` 저장 |
| `scripts/SCRIPT_GUIDE.md` | 쉘 스크립트 상세 해설 |

스크립트 상세 설명은 다음 파일을 읽는다.

```bash
cd /mnt/mac/Users/wlgjs060614351/Desktop/Troubleshooting_LinuxProcesses_and_System-Resources
less scripts/SCRIPT_GUIDE.md
```

먼저 준비 스크립트를 실행한다.

```bash
cd /mnt/mac/Users/wlgjs060614351/Desktop/Troubleshooting_LinuxProcesses_and_System-Resources
./scripts/prepare.sh
ss -ltnp | grep ':15034' || true
```

`ss` 출력이 없으면 `15034` 포트가 비어 있다는 뜻이다.

`prepare.sh`가 만드는 것:

```text
agent-app-leak 압축 해제
agent-app-leak 실행 권한 부여
.agent-home/upload_files 생성
.agent-home/api_keys/secret.key 생성
evidence/logs 생성
evidence/monitor 생성
evidence/snapshots 생성
reports 생성
```

---

## 5. 공통 실험 규칙

이 실습에서는 터미널을 보통 2개 또는 3개 쓴다.

```text
터미널 B: monitor.sh 관제
터미널 A: run_agent.sh 실행
터미널 C: snapshot.sh 순간 증거 저장
```

순서는 중요하다.

```text
1. 터미널 B에서 monitor.sh를 먼저 켠다.
2. 터미널 A에서 앱을 실행한다.
3. 필요한 순간에 터미널 C에서 snapshot.sh를 실행한다.
4. 종료 후 evidence 파일을 확인한다.
5. reports 파일에 핵심 증거를 정리한다.
```

왜 monitor를 먼저 켜는가:

```text
OOM은 10초 안에 종료될 수 있다.
앱을 먼저 실행하면 monitor가 PID를 잡기 전에 프로세스가 사라질 수 있다.
```

왜 PID 하나가 아니라 `PID_FAMILY`를 보는가:

```text
agent-app-leak은 부모 프로세스와 자식 프로세스로 나뉘어 실행된다.
실제 메모리를 쓰거나 종료되는 PID가 자식 프로세스일 수 있다.
monitor.sh는 부모 PID와 직접 자식 PID를 함께 합산한다.
```

---

## 6. OOM Crash: 메모리가 차오르는 장면

### 6.1 목표

```text
MEMORY_LIMIT=64에서 RSS/Heap 증가 후 MemoryGuard 종료를 확인한다.
MEMORY_LIMIT=512에서 같은 MemoryGuard 종료가 사라지는지 비교한다.
```

### 6.2 Before: 낮은 메모리 제한

터미널 B:

```bash
cd /mnt/mac/Users/wlgjs060614351/Desktop/Troubleshooting_LinuxProcesses_and_System-Resources
./scripts/monitor.sh agent-app-leak oom_before 2
```

터미널 A:

```bash
cd /mnt/mac/Users/wlgjs060614351/Desktop/Troubleshooting_LinuxProcesses_and_System-Resources
MEMORY_LIMIT=64 CPU_MAX_OCCUPY=100 MULTI_THREAD_ENABLE=false ./scripts/run_agent.sh
```

확인:

```bash
cd /mnt/mac/Users/wlgjs060614351/Desktop/Troubleshooting_LinuxProcesses_and_System-Resources
tail -n 30 evidence/monitor/oom_before_*.log
grep -RniE 'MemoryGuard|Memory limit|Self-terminating|Killed' evidence/logs
```

### 6.3 After: 메모리 제한 상향

터미널 B:

```bash
cd /mnt/mac/Users/wlgjs060614351/Desktop/Troubleshooting_LinuxProcesses_and_System-Resources
./scripts/monitor.sh agent-app-leak oom_after 2
```

터미널 A:

```bash
cd /mnt/mac/Users/wlgjs060614351/Desktop/Troubleshooting_LinuxProcesses_and_System-Resources
MEMORY_LIMIT=512 CPU_MAX_OCCUPY=100 MULTI_THREAD_ENABLE=false ./scripts/run_agent.sh
```

해석:

```text
MEMORY_LIMIT=64에서는 Heap 75MB에서 MemoryGuard가 종료했다.
MEMORY_LIMIT=512에서는 MemoryGuard 종료 없이 다음 단계인 CpuWorker까지 진행했다.
```

리포트:

```text
reports/01-oom-crash.md
```

---

## 7. CPU Spike와 운영체제 스케줄링

CPU 장애와 스케줄링은 함께 이해하는 것이 좋다. CPU Spike는 특정 프로세스가 CPU time을 많이 요구하는 문제이고, 스케줄링은 운영체제가 CPU time을 누구에게 줄지 정하는 문제다.

### 7.1 CPU Spike 재현

목표:

```text
CPU_MAX_OCCUPY=100에서 CpuWorker 부하 상승과 CPU Threshold 종료를 확인한다.
CPU_MAX_OCCUPY=10에서 10% 피크 후 cooldown되는 것을 확인한다.
```

터미널 B:

```bash
cd /mnt/mac/Users/wlgjs060614351/Desktop/Troubleshooting_LinuxProcesses_and_System-Resources
./scripts/monitor.sh agent-app-leak cpu_spike 1
```

터미널 A:

```bash
cd /mnt/mac/Users/wlgjs060614351/Desktop/Troubleshooting_LinuxProcesses_and_System-Resources
MEMORY_LIMIT=512 CPU_MAX_OCCUPY=100 MULTI_THREAD_ENABLE=false ./scripts/run_agent.sh
```

확인:

```bash
cd /mnt/mac/Users/wlgjs060614351/Desktop/Troubleshooting_LinuxProcesses_and_System-Resources
tail -n 40 evidence/monitor/cpu_spike_*.log
grep -RniE 'CpuWorker|CPU Threshold|Threshold|Terminated' evidence/logs
```

### 7.2 CPU 완화 조건

터미널 B:

```bash
cd /mnt/mac/Users/wlgjs060614351/Desktop/Troubleshooting_LinuxProcesses_and_System-Resources
./scripts/monitor.sh agent-app-leak cpu_limited 1
```

터미널 A:

```bash
cd /mnt/mac/Users/wlgjs060614351/Desktop/Troubleshooting_LinuxProcesses_and_System-Resources
MEMORY_LIMIT=512 CPU_MAX_OCCUPY=10 MULTI_THREAD_ENABLE=false ./scripts/run_agent.sh
```

터미널 C:

```bash
cd /mnt/mac/Users/wlgjs060614351/Desktop/Troubleshooting_LinuxProcesses_and_System-Resources
./scripts/snapshot.sh cpu_limited_running
```

확인:

```bash
cd /mnt/mac/Users/wlgjs060614351/Desktop/Troubleshooting_LinuxProcesses_and_System-Resources
grep -RniE 'Peak reached|cooldown|CpuWorker' evidence/logs
ls -lt evidence/snapshots | head
```

### 7.3 스케줄링 추론

`CPU_MAX_OCCUPY=10`, `MULTI_THREAD_ENABLE=false` 조건에서는 정상 모니터링 시나리오가 실행되며 스케줄러 로그가 나온다.

증거 파일:

```text
evidence/logs/run_20260522_190338.log
evidence/logs/run_20260522_191636.log
```

대표 패턴:

```text
Thread-A Task Started. Calculating... (20%)
Thread-A Calculating... (40%)
Thread-A Preempted. Progress saved at (40%)
Thread-B Task Started. Calculating... (20%)
Thread-B Calculating... (40%)
Thread-B Preempted. Progress saved at (40%)
Thread-C Task Started. Calculating... (20%)
Thread-C Calculating... (40%)
Thread-C Preempted. Progress saved at (40%)
Thread-A Resumed. Calculating... (60%)
```

분석:

```text
FCFS라면 Thread-A가 100% 완료된 뒤 Thread-B가 시작되어야 한다.
Priority라면 특정 스레드가 반복적으로 우선 실행되는 경향이 있어야 한다.
하지만 로그에서는 A, B, C가 비슷한 단위로 번갈아 실행된다.
따라서 Round-Robin 형태의 시간 분할 스케줄링으로 추론할 수 있다.
```

운영 관점:

```text
Round-Robin은 여러 작업에 공평하게 CPU 기회를 나눠 준다.
응답성을 중시하는 웹 서버나 인터랙티브 작업에 잘 맞는다.
다만 문맥 교환이 너무 잦으면 오버헤드가 생길 수 있다.
```

리포트:

```text
reports/02-cpu-latency.md
```

---

## 8. Deadlock: 살아 있지만 앞으로 가지 못하는 프로세스

Deadlock은 프로세스가 죽는 장애가 아니다. 오히려 PID는 살아 있다. 문제는 스레드들이 서로의 자원을 기다리느라 더 이상 앞으로 가지 못한다는 점이다.

### 8.1 실패했던 조건

처음에는 다음 조건으로 시도했다.

```bash
MEMORY_LIMIT=512 CPU_MAX_OCCUPY=100 MULTI_THREAD_ENABLE=true ./scripts/run_agent.sh
```

이 조건에서는 Deadlock 경고는 나왔지만 CPU 보호 종료가 먼저 발생했다. 그래서 Deadlock 확정 증거로는 부족했다.

### 8.2 Deadlock 재현 조건

CPU 보호 종료를 피하고 멀티스레드 락 경로를 관찰하기 위해 CPU 제한을 낮춘다.

터미널 B:

```bash
cd /mnt/mac/Users/wlgjs060614351/Desktop/Troubleshooting_LinuxProcesses_and_System-Resources
./scripts/monitor.sh agent-app-leak deadlock_retry 2
```

터미널 A:

```bash
cd /mnt/mac/Users/wlgjs060614351/Desktop/Troubleshooting_LinuxProcesses_and_System-Resources
MEMORY_LIMIT=512 CPU_MAX_OCCUPY=10 MULTI_THREAD_ENABLE=true ./scripts/run_agent.sh
```

터미널 C에서 20초 뒤:

```bash
cd /mnt/mac/Users/wlgjs060614351/Desktop/Troubleshooting_LinuxProcesses_and_System-Resources
./scripts/snapshot.sh deadlock_retry_waiting_1
```

터미널 C에서 40초 뒤:

```bash
cd /mnt/mac/Users/wlgjs060614351/Desktop/Troubleshooting_LinuxProcesses_and_System-Resources
./scripts/snapshot.sh deadlock_retry_waiting_2
```

확인:

```bash
cd /mnt/mac/Users/wlgjs060614351/Desktop/Troubleshooting_LinuxProcesses_and_System-Resources
tail -n 60 evidence/monitor/deadlock_retry_*.log
grep -RniE 'WAITING|BLOCKED|LOCK|deadlock|Deadlock|POTENTIAL|Threshold' evidence/logs
ls -lt evidence/snapshots | head
```

확정 증거:

```text
Worker-Thread-1: Shared_Memory_A를 잡고 Socket_Pool_B를 기다림
Worker-Thread-2: Socket_Pool_B를 잡고 Shared_Memory_A를 기다림
마지막 로그: WAITING / BLOCKED
PID: 계속 존재
CPU/RSS: 긴 시간 정체
top -H: 스레드들이 sleeping 상태
```

### 8.3 Deadlock 회피 조건

`MULTI_THREAD_ENABLE=false`는 멀티스레드 락 경로를 끄는 회피 조건이다.

터미널 B:

```bash
cd /mnt/mac/Users/wlgjs060614351/Desktop/Troubleshooting_LinuxProcesses_and_System-Resources
./scripts/monitor.sh agent-app-leak deadlock_avoid 2
```

터미널 A:

```bash
cd /mnt/mac/Users/wlgjs060614351/Desktop/Troubleshooting_LinuxProcesses_and_System-Resources
MEMORY_LIMIT=512 CPU_MAX_OCCUPY=10 MULTI_THREAD_ENABLE=false ./scripts/run_agent.sh
```

터미널 C에서 실행 중 두 번:

```bash
cd /mnt/mac/Users/wlgjs060614351/Desktop/Troubleshooting_LinuxProcesses_and_System-Resources
./scripts/snapshot.sh deadlock_avoid_running
```

확인:

```bash
cd /mnt/mac/Users/wlgjs060614351/Desktop/Troubleshooting_LinuxProcesses_and_System-Resources
tail -n 60 evidence/monitor/deadlock_avoid_*.log
grep -RniE 'WAITING|BLOCKED|LOCK|POTENTIAL DEADLOCK|Concurrency: False|SYSTEM STATUS: STABLE' evidence/logs
```

비교:

| 항목 | 재현 조건 | 회피 조건 |
|---|---|---|
| `MULTI_THREAD_ENABLE` | `true` | `false` |
| 시작 상태 | `POTENTIAL DEADLOCK` | `SYSTEM STATUS: STABLE` |
| 마지막 핵심 로그 | `WAITING`, `BLOCKED` | 스케줄러/워커 로그 진행 |
| 락 관계 | 서로 상대 자원 대기 | 순환 락 대기 없음 |
| 결론 | Deadlock 발생 | Deadlock 회피 |

리포트:

```text
reports/03-deadlock.md
```

---

## 9. 미션을 진행하면서 개인적으로 궁금했던 것들

Q. 프로세스와 스레드의 차이는?

```text
프로세스는 독립된 주소 공간과 자원을 가진 실행 단위이고, 스레드는 같은 프로세스 안에서 메모리를 공유하는 실행 흐름이다.
```

Q. RSS와 VSZ의 차이는?

```text
RSS는 실제 물리 메모리에 올라온 크기이고, VSZ는 프로세스가 확보한 가상 메모리 크기다.
```

Q. MemoryGuard는 누가 작동시키는가?

```text
Linux 커널이 아니라 agent-app-leak 애플리케이션 내부 로직이다.
내가 작성한 코드는 아니고 제공된 바이너리 안에 구현된 보호 정책으로 보면 된다.
MEMORY_LIMIT 환경변수를 기준으로 Heap 사용량을 감시하다가 제한을 넘으면 스스로 종료한다.
```

Q. MemoryGuard가 작동한 뒤에 CpuWorker가 실행되는가?

```text
항상 그렇지 않다.
MEMORY_LIMIT=64에서는 MemoryGuard가 먼저 프로세스를 종료해서 CpuWorker까지 가지 못했다.
MEMORY_LIMIT=512에서는 MemoryGuard 종료를 피했기 때문에 다음 워크로드인 CpuWorker가 관측되었다.
즉, MemoryGuard가 CpuWorker를 실행시키는 것이 아니라, MemoryGuard에 걸리지 않았을 때 다음 단계로 진행된 것이다.
```

Q. CPU 과점유가 왜 지연을 만드는가?

```text
CPU-bound 프로세스가 CPU time을 오래 요구하면 다른 프로세스나 스레드가 실행 대기열에서 더 오래 기다린다.
그 결과 요청 처리나 이벤트 응답이 늦어진다.
```

Q. 이번 스케줄링 로그는 어떤 알고리즘으로 보이는가?

```text
Thread-A, B, C가 하나씩 끝까지 실행되지 않고 짧은 단위로 번갈아 실행된다.
따라서 FCFS나 Priority보다는 Round-Robin 형태의 시간 분할 스케줄링으로 추론할 수 있다.
```

Q. Deadlock의 4대 조건은?

```text
상호 배제, 점유 대기, 비선점, 순환 대기다.
```

Q. 이번 Deadlock은 왜 확정할 수 있는가?

```text
마지막 로그가 WAITING/BLOCKED에서 멈췄고, PID는 계속 살아 있었다.
CPU/RSS 변화도 정체되었고, ps -L/top -H에서 스레드들이 대기 상태로 남아 있었다.
로그상 Thread-1과 Thread-2가 서로 상대방의 자원을 기다리는 순환 대기 구조도 확인되었다.
```

Q. Deadlock의 임시 조치는 무엇인가?

```text
MULTI_THREAD_ENABLE=false로 멀티스레드 락 경로를 끄는 것이다.
근본 해결은 모든 스레드가 같은 순서로 락을 잡게 하거나, timeout/try-lock을 적용해 순환 대기를 끊는 것이다.
```
