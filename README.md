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
6. 증거를 읽는 법
7. OOM Crash: 메모리가 차오르는 장면
8. CPU Spike와 운영체제 스케줄링
9. Deadlock: 살아 있지만 앞으로 가지 못하는 프로세스
10. 장애 리포트 작성법
11. 미션을 진행하면서 개인적으로 궁금했던 것들

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

조금 더 쉽게 말하면, CPU는 식당의 조리대와 비슷하다. 주문은 여러 개 들어오지만 조리대는 한정되어 있다. 운영체제 스케줄러는 “어떤 주문을 먼저 조리대에 올릴지”, “한 주문이 조리대를 얼마나 오래 쓸 수 있는지”를 결정한다.

대표적인 스케줄링 알고리즘은 다음과 같다.

| 알고리즘 | 기준 | 쉬운 예시 | 장점 | 단점 |
|---|---|---|---|---|
| FCFS | 먼저 온 작업을 먼저 끝까지 처리 | 은행 번호표 순서대로 한 명씩 끝까지 처리 | 단순하고 예측하기 쉽다 | 앞 작업이 오래 걸리면 뒤 작업이 모두 기다린다 |
| Round-Robin | 각 작업에 같은 시간 조각을 번갈아 부여 | A, B, C에게 1분씩 돌아가며 발표 기회 제공 | 여러 작업이 공평하게 진행되고 응답성이 좋다 | 문맥 교환이 잦으면 오버헤드가 생긴다 |
| Priority | 우선순위가 높은 작업을 먼저 처리 | 응급실에서 중증 환자를 먼저 진료 | 중요한 작업을 빨리 처리할 수 있다 | 낮은 우선순위 작업이 오래 밀릴 수 있다 |

운영체제는 실제로 더 복잡한 정책을 쓰지만, 이 미션에서는 로그 패턴을 보고 위 세 가지 중 어느 쪽에 가까운지 추론하면 된다.

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

Deadlock을 설명할 때 가장 유명한 비유가 식사하는 철학자들 문제(Dining Philosophers Problem)다.

```text
원탁에 철학자 5명이 앉아 있다.
각 철학자 사이에는 포크가 하나씩 있다.
철학자는 밥을 먹으려면 왼쪽 포크와 오른쪽 포크를 모두 들어야 한다.
모든 철학자가 동시에 왼쪽 포크를 먼저 들었다.
이제 모든 철학자는 오른쪽 포크를 기다린다.
하지만 오른쪽 포크는 이미 옆 철학자가 들고 있다.
아무도 포크를 내려놓지 않으면 모두 영원히 기다린다.
```

이 비유에서 철학자는 스레드이고, 포크는 락이 걸린 공유 자원이다. 밥을 먹는 행위는 작업을 완료하는 것이다. 포크 하나만 들고는 밥을 먹을 수 없듯이, 이번 실험의 스레드도 하나의 자원만 잡고는 작업을 끝낼 수 없었다.

이번 `agent-app-leak` 실험에 대응시키면 다음과 같다.

| 식사하는 철학자들 | 이번 실험 |
|---|---|
| 철학자 | `Worker-Thread-1`, `Worker-Thread-2` |
| 포크 | `Shared_Memory_A`, `Socket_Pool_B` |
| 왼쪽 포크를 든 상태 | Thread-1이 `Shared_Memory_A`를 점유 |
| 오른쪽 포크를 기다림 | Thread-1이 `Socket_Pool_B`를 기다림 |
| 옆 철학자가 포크를 들고 있음 | Thread-2가 `Socket_Pool_B`를 점유 |
| 모두 기다림 | 두 스레드가 `WAITING/BLOCKED`에서 멈춤 |

Deadlock 4대 조건:

| 조건 | 영어 표현 | 뜻 | 이번 실험에서의 예 |
|---|---|---|---|
| 상호 배제 | Mutual Exclusion | 한 자원을 동시에 여러 스레드가 쓸 수 없음 | `Shared_Memory_A`, `Socket_Pool_B`는 한 번에 한 스레드만 잡을 수 있다 |
| 점유 대기 | Hold and Wait | 이미 잡은 자원을 놓지 않고 다른 자원을 기다림 | Thread-1은 `Shared_Memory_A`를 잡고 `Socket_Pool_B`를 기다린다 |
| 비선점 | No Preemption | 남이 잡은 자원을 강제로 빼앗을 수 없음 | Thread-1은 Thread-2가 잡은 `Socket_Pool_B`를 빼앗지 못한다 |
| 순환 대기 | Circular Wait | 서로가 서로의 자원을 기다리는 고리 형성 | Thread-1은 Thread-2의 자원을, Thread-2는 Thread-1의 자원을 기다린다 |

Deadlock을 해결하거나 예방하는 방법은 이 네 조건 중 하나를 깨는 것이다. 예를 들어 모든 스레드가 항상 같은 순서로 락을 잡게 하면 순환 대기를 막을 수 있다. 또는 두 번째 락을 일정 시간 안에 얻지 못하면 첫 번째 락을 내려놓고 다시 시도하게 만들 수도 있다.

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

부모 PID와 자식 PID를 모두 보는 것이 모든 상황에서 항상 필수는 아니다. 단일 프로세스로만 동작하는 프로그램이라면 하나의 PID만 관찰해도 충분할 수 있다. 그러나 운영 환경의 많은 프로그램은 실행 중에 자식 프로세스를 만들거나, 실제 작업을 worker 프로세스에 맡긴다. 이 경우 부모 PID만 보면 자원 사용량을 잘못 해석할 수 있다.

이번 실습에서는 두 PID를 함께 보는 것이 필요했다. `agent-app-leak`은 부모 프로세스가 실행 흐름을 시작하고, 자식 프로세스가 실제 워커 작업을 수행하는 구조로 관측되었다. OOM 실험에서 RSS 증가와 자기 종료 로그가 자식 프로세스 쪽 작업과 연결되었기 때문에, 부모 PID만 보면 앱 전체의 메모리 증가를 놓칠 수 있었다.

정리하면 다음과 같다.

| 상황 | 하나의 PID만 봐도 되는가 | 이유 |
|---|---|---|
| 단일 프로세스 앱 | 대체로 가능 | 실제 작업과 자원 사용이 한 PID 안에 있다 |
| 부모가 자식 프로세스를 만드는 앱 | PID family 확인 필요 | 실제 CPU/RSS 증가가 자식에서 발생할 수 있다 |
| 웹 서버, 워커, 배치 프로세스 구조 | PID family 또는 프로세스 트리 확인 필요 | master/worker 구조가 흔하다 |
| Deadlock처럼 스레드 상태가 중요한 경우 | PID family와 thread 확인 필요 | 부모/자식뿐 아니라 스레드 단위 상태도 봐야 한다 |

그래서 이 실습의 관제 기준은 “처음 찾은 root PID 하나”가 아니라 “root PID와 그 자식 PID를 묶은 PID family”다.

---

## 6. 증거를 읽는 법

장애 분석에서 가장 중요한 습관은 하나의 로그만 보고 결론 내리지 않는 것이다. 앱 로그는 애플리케이션 내부에서 무슨 일이 있었는지 말해 주고, `ps`와 `top`은 운영체제가 본 프로세스 상태를 보여 준다. 둘을 나란히 놓고 같은 실행 흐름인지 확인해야 한다.

이번 실습에서 남기는 증거는 크게 세 종류다.

| 증거 | 위치 | 역할 |
|---|---|---|
| 실행 로그 | `evidence/logs/run_*.log` | 앱이 스스로 남긴 이벤트, 보호 정책, 워커 진행 상태 |
| 관제 로그 | `evidence/monitor/*.log`, `*.csv` | 시간에 따른 CPU/MEM/RSS/VSZ/스레드 수 변화 |
| 스냅샷 | `evidence/snapshots/*.txt` | 특정 순간의 프로세스/스레드 상태 |

### 6.1 앱 로그와 시스템 관제의 차이

앱 로그는 애플리케이션 내부 관점이다.

```text
[MemoryGuard] Memory limit exceeded
[CpuWorker] CPU Threshold Violated
[AgentWorker] WAITING ... (Status: BLOCKED)
```

이런 로그는 “앱이 왜 그런 결정을 했는가”를 설명한다.

시스템 관제는 운영체제 관점이다.

```text
CPU:1.4% MEM:2.1% RSS:356788KB VSZ:576308KB THR:4 ELAPSED:01:46
```

이런 값은 “그 순간 프로세스가 실제로 살아 있었는가”, “메모리가 늘었는가”, “스레드 수가 몇 개인가”를 보여 준다.

둘은 항상 같은 숫자로 맞아야 하는 관계가 아니다. 예를 들어 앱 로그의 `Current Load: 57.37%`는 앱 내부 `CpuWorker`가 계산한 부하이고, monitor의 `CPU:1.3%`는 `ps`가 본 프로세스 CPU time 비율이다. 이름은 둘 다 CPU처럼 보이지만 출처와 의미가 다르다.

### 6.2 샘플링 간격

`monitor.sh`는 일정 간격으로 상태를 찍는다.

```bash
./scripts/monitor.sh agent-app-leak cpu_spike 1
./scripts/monitor.sh agent-app-leak deadlock_retry 2
```

마지막 숫자가 interval이다. `1`이면 1초마다, `2`이면 2초마다 관제한다. 그래서 짧게 끝나는 OOM이나 CPU 종료 실험은 interval을 너무 길게 잡으면 중요한 순간을 놓칠 수 있다.

단, interval은 모든 순간을 빠짐없이 기록한다는 뜻은 아니다. 프로세스 상태는 샘플과 샘플 사이에도 변한다. 그래서 빠른 장애는 앱 로그와 monitor 로그를 함께 봐야 한다.

### 6.3 프로세스 상태 문자 읽기

`ps`와 `top`에는 `STAT` 또는 `S` 같은 상태 문자가 나온다.

| 상태 | 뜻 | 실습에서의 해석 |
|---|---|---|
| `R` | Running 또는 runnable | CPU에서 실행 중이거나 실행 대기 중 |
| `S` | Interruptible sleep | 이벤트, I/O, 락 등을 기다리는 일반 대기 상태 |
| `D` | Uninterruptible sleep | 주로 커널 I/O 대기, 신호로도 깨우기 어려움 |
| `T` | Stopped | 중지됨 |
| `Z` | Zombie | 종료됐지만 부모가 아직 회수하지 않음 |

이번 Deadlock 스냅샷에서 스레드들은 `S` 계열 상태로 보인다. 이것만으로 Deadlock을 단정하지는 않는다. 하지만 마지막 앱 로그가 `WAITING/BLOCKED`이고, PID가 계속 살아 있으며, CPU/RSS가 정체되어 있다면 강한 보조 증거가 된다.

### 6.4 종료 원인 구분하기

프로세스가 사라졌다고 해서 모두 같은 장애는 아니다. 원인을 구분해야 조치도 달라진다.

| 종료/정지 형태 | 흔한 증거 | 이번 실습의 예 |
|---|---|---|
| 앱 내부 보호 종료 | 앱 로그에 `Self-terminating`, `Threshold Violated` | MemoryGuard, CpuWorker |
| 커널 OOM Killer | `dmesg`나 시스템 로그에 `Out of memory`, `Killed process` | 이번 OOM 리포트의 직접 원인은 아님 |
| 정상 종료 | 완료 로그와 exit code 0 | 장애 재현과 구분 필요 |
| Deadlock | PID는 살아 있고 로그 진행이 멈춤 | `WAITING/BLOCKED`, 낮은 CPU, sleeping threads |

따라서 OOM 리포트에서는 “커널 OOM Killer가 죽였다”고 쓰면 안 된다. 증거상 앱 내부 `MemoryGuard`가 `MEMORY_LIMIT` 기준으로 자기 종료를 수행했다.

### 6.5 좋은 증거의 조건

좋은 장애 리포트는 결론보다 증거가 먼저 보인다.

```text
언제 실행했는가
어떤 환경변수였는가
어떤 PID family였는가
마지막 앱 로그는 무엇인가
CPU/RSS/THR은 시간에 따라 어떻게 변했는가
Before와 After에서 무엇이 달라졌는가
```

이 여섯 가지가 있으면 다른 사람이 같은 결론에 도달할 수 있다. 반대로 “느린 것 같다”, “죽은 것 같다”, “멈춘 것 같다”처럼 느낌만 있으면 재현과 검증이 어렵다.

---

## 7. OOM Crash: 메모리가 차오르는 장면

### 7.1 목표

```text
MEMORY_LIMIT=64에서 RSS/Heap 증가 후 MemoryGuard 종료를 확인한다.
MEMORY_LIMIT=512에서 같은 MemoryGuard 종료가 사라지는지 비교한다.
```

메모리 누수란 프로그램이 실행 중에 메모리를 할당해 놓고, 더 이상 사용하지 않는데도 해제하지 않아 메모리 사용량이 계속 증가하는 현상이다.

프로그램은 요청 처리, 파일 읽기, 캐시 저장 같은 작업을 하면서 필요한 데이터를 Heap에 올린다. 정상적인 경우라면 작업이 끝난 뒤 필요 없어진 메모리는 반환되어야 한다. 그런데 반환되지 않으면 운영체제 입장에서는 그 메모리가 아직 사용 중인 것으로 보인다. 그래서 다른 작업이나 다른 프로세스가 그 메모리를 다시 사용할 수 없다.

이 상태가 반복되면 RSS와 Heap 사용량이 시간이 지날수록 계속 증가한다. 처음에는 별문제 없어 보일 수 있지만, 어느 순간 메모리 제한에 도달하면 앱 내부 MemoryGuard가 프로세스를 종료하거나, 더 심한 경우 Linux 커널 OOM Killer가 프로세스를 강제로 종료할 수 있다.

즉, 메모리 누수의 핵심은 단순히 “메모리를 많이 쓴다”가 아니다. “더 이상 필요 없는 메모리가 회수되지 않고 계속 남아 있다”는 점이다. 그래서 OOM 실험에서는 현재 메모리 사용량뿐 아니라 RSS와 Heap이 계속 증가하는지, 그리고 GC나 정리 작업 이후에도 내려가지 않는지를 함께 본다.

### 7.2 Before: 낮은 메모리 제한

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

### 7.3 After: 메모리 제한 상향

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

### 7.4 실무 대응과 예방

실무에서 OOM이 발생하면 프로세스가 갑자기 종료될 수 있다. 사용자는 요청 중간에 오류를 보거나, 연결이 끊기거나, 잠시 후 재시도해야 할 수 있다. 서버가 여러 대라면 일부 요청만 실패할 수 있고, 서버가 한 대뿐이라면 서비스 전체가 멈춘 것처럼 보일 수 있다.

OOM은 연쇄 장애로 이어질 수도 있다. 한 인스턴스가 죽으면 남은 인스턴스가 더 많은 요청을 받게 된다. 그러면 남은 인스턴스의 메모리 사용량도 빠르게 증가할 수 있다. 결국 하나의 프로세스 문제가 여러 인스턴스의 장애로 번질 수 있다.

대표적인 영향은 다음과 같다.

| 영향 | 설명 |
|---|---|
| 요청 실패 | 처리 중이던 요청이 중간에 끊기거나 500 오류가 발생한다 |
| 재시작 반복 | 메모리가 다시 차면 프로세스가 계속 죽고 살아나기를 반복한다 |
| 응답 지연 | 재시작 중인 인스턴스가 많아지면 남은 인스턴스에 요청이 몰린다 |
| 데이터 처리 중단 | 배치나 업로드 작업이 중간에 실패할 수 있다 |
| 원인 분석 어려움 | 재시작 후에는 장애 직전의 메모리 상태가 사라질 수 있다 |

운영 환경에서 OOM이 발생하면 먼저 “누가 프로세스를 종료했는가”를 확인한다. Linux 커널이 종료했는지, 애플리케이션이 스스로 종료했는지, 컨테이너의 메모리 제한에 걸렸는지에 따라 해결 방법이 달라진다.

OOM이 나면 급해서 바로 재시작하고 싶어진다. 재시작은 서비스를 잠깐 살릴 수 있지만, 장애 직전의 메모리 상태와 마지막 로그를 지워 버릴 수 있다. 그래서 가능하면 재시작 전에 짧게라도 증거를 남긴다.

즉시 대응은 다음 순서로 진행한다. 목표는 사용자의 불편을 줄이면서, 나중에 원인을 찾을 수 있는 자료도 남기는 것이다.

```text
1. 마지막 로그와 메트릭을 저장한다.
2. RSS, Heap, 컨테이너 메모리 사용량을 확인한다.
3. OOM Killer 로그가 있는지 확인한다.
4. 최근 배포나 트래픽 증가가 있었는지 확인한다.
5. 급하면 메모리 제한이나 인스턴스 수를 임시로 늘린다.
```

각 단계의 의미는 다음과 같다.

| 단계 | 왜 필요한가 |
|---|---|
| 로그와 메트릭 저장 | 재시작하면 장애 직전 상태가 사라질 수 있다 |
| RSS/Heap 확인 | 실제로 메모리가 늘었는지 확인한다 |
| OOM Killer 로그 확인 | Linux 커널이 죽였는지 앱이 스스로 죽었는지 구분한다 |
| 최근 변경 확인 | 새 배포나 트래픽 증가가 원인일 수 있다 |
| limit/replica 조정 | 원인을 고치기 전까지 시간을 벌 수 있다 |

메모리 제한을 높이는 것은 빠른 완화책이 될 수 있다. 예를 들어 평소에도 400MB 가까이 쓰는 앱에 512MB 제한을 걸어 두면, 트래픽이 조금만 늘어도 위험해질 수 있다. 이때 제한을 넉넉히 올리는 것은 도움이 된다. 하지만 메모리 누수가 있다면 언젠가 다시 메모리가 찬다. 그래서 메모리 제한 상향은 원인을 고치는 조치라기보다 시간을 버는 조치다.

근본 해결은 메모리가 계속 증가하는 경로를 찾는 것이다.

| 원인 후보 | 점검 방법 | 개선 방향 |
|---|---|---|
| 객체 누수 | Heap dump, allocation profile | 불필요한 참조 제거, 객체 생명주기 정리 |
| 무제한 캐시 | 캐시 크기와 hit ratio 확인 | TTL, LRU, 최대 크기 제한 |
| 큰 요청/응답 | payload 크기, 업로드 크기 확인 | 요청 크기 제한, streaming 처리 |
| 배치 작업 | 배치 단위와 동시성 확인 | chunk 처리, backpressure, 작업 큐 분리 |
| 컨테이너 limit 과소 설정 | 실제 peak와 limit 비교 | request/limit 재산정, headroom 확보 |

예를 들어 캐시가 원인이라면 캐시를 모두 없애는 것이 정답은 아닐 수 있다. 캐시는 성능을 위해 필요하다. 대신 캐시가 너무 커지지 않도록 최대 크기나 만료 시간을 정한다. 큰 파일이 문제라면 한 번에 모두 메모리에 올리지 말고 조금씩 나누어 처리한다.

예방을 위해서는 메모리 사용량의 절대값뿐 아니라 증가 속도를 함께 본다. RSS가 천천히라도 계속 우상향하면 장애 전조일 수 있다.

```text
memory usage > 80%가 일정 시간 지속
RSS 증가율이 평소보다 높음
GC 이후에도 Heap이 내려가지 않음
OOM kill count 증가
```

알림은 너무 늦게 울리면 대응할 시간이 없다. 보통은 경고 단계와 위험 단계를 나누어 둔다.

```text
warning: memory usage 80% 이상이 5분 지속
critical: memory usage 90% 이상이 3분 지속
critical: OOM kill count 증가
```

이렇게 알림을 나누어 두면 장애가 커지기 전에 확인하고 조치할 수 있다.

리포트:

```text
reports/01-oom-crash.md
```

---

## 8. CPU Spike와 운영체제 스케줄링

CPU 장애와 스케줄링은 함께 이해하는 것이 좋다. CPU Spike는 특정 프로세스가 CPU time을 많이 요구하는 문제이고, 스케줄링은 운영체제가 CPU time을 누구에게 줄지 정하는 문제다.

### 8.1 CPU Spike 재현

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

### 8.2 CPU 완화 조건

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

### 8.3 보너스 과제: 스케줄링 알고리즘 추론

정상 실행 로그에는 `Thread-A`, `Thread-B`, `Thread-C`가 순서대로 조금씩 실행되는 패턴이 나온다. 이 로그를 이용하면 현재 프로그램의 작업 실행 방식이 FCFS, Priority, Round-Robin 중 어느 방식에 가까운지 추론할 수 있다.

README에서는 핵심만 정리한다.

```text
Thread-A가 100% 완료되기 전에 Thread-B가 실행된다.
Thread-B가 100% 완료되기 전에 Thread-C가 실행된다.
이후 다시 Thread-A, Thread-B, Thread-C가 이어서 실행된다.
```

이 패턴은 하나의 작업을 끝까지 처리하는 FCFS와는 다르다. 또한 특정 스레드만 계속 우선 실행되는 모습도 아니므로 Priority 방식으로 보기 어렵다. 여러 작업이 짧은 실행 기회를 나누어 갖는다는 점에서 Round-Robin 형태에 가깝다.

자세한 분석은 별도 리포트에 정리했다.

```text
reports/04-scheduling-analysis.md
```

### 8.4 실무 대응과 예방

실무에서 CPU Spike가 발생하면 서비스가 느려질 수 있다. 프로세스가 죽지는 않더라도 CPU를 오래 쓰는 작업 때문에 다른 요청이 기다리게 된다. 사용자는 페이지가 늦게 열리거나, API 응답이 늦어지거나, timeout 오류를 볼 수 있다.

CPU Spike는 비용 문제로도 이어질 수 있다. 클라우드 환경에서는 CPU 사용량이 높아지면 autoscaling이 동작해 인스턴스가 늘어날 수 있다. 이 조치가 필요할 때도 있지만, 비효율적인 코드가 원인이라면 같은 일을 처리하는 데 더 많은 서버 비용이 든다.

대표적인 영향은 다음과 같다.

| 영향 | 설명 |
|---|---|
| 응답 지연 | CPU를 오래 쓰는 작업 때문에 다른 요청이 기다린다 |
| timeout 증가 | 사용자가 응답을 받기 전에 제한 시간이 끝난다 |
| 처리량 감소 | 같은 시간 동안 처리할 수 있는 요청 수가 줄어든다 |
| 비용 증가 | 인스턴스가 늘거나 CPU 사용량이 높아져 비용이 증가한다 |
| 장애 전파 | CPU가 높은 서비스가 DB나 다른 API 호출을 늦게 반환해 다른 서비스도 영향을 받을 수 있다 |

CPU Spike가 발생하면 먼저 “누가 CPU를 많이 쓰고 있는지”를 찾는다. 전체 서버가 바쁜 것인지, 특정 프로세스 하나가 바쁜 것인지, 특정 API 요청 때문에 바쁜 것인지 구분해야 한다.

CPU가 높다고 해서 모두 같은 문제는 아니다. 트래픽이 갑자기 늘었을 수도 있고, 새로 배포한 코드가 비효율적일 수도 있다. 또는 어떤 반복문이 끝나지 않고 계속 CPU를 쓰는 상황일 수도 있다.

실무에서는 다음 순서로 확인한다.

```text
1. top, ps 같은 도구로 CPU를 많이 쓰는 프로세스를 찾는다.
2. 최근 배포가 있었는지 확인한다.
3. 갑자기 많이 호출된 API가 있는지 확인한다.
4. 오래 걸리는 계산이 사용자 요청 안에서 바로 실행되는지 확인한다.
5. 급한 경우 인스턴스를 늘리거나 요청량을 제한해 서비스를 안정화한다.
```

각 단계의 의미는 다음과 같다.

| 단계 | 왜 필요한가 |
|---|---|
| CPU를 쓰는 프로세스 확인 | 문제 범위를 먼저 좁힌다 |
| 최근 배포 확인 | 새 코드가 원인인지 확인한다 |
| API 호출량 확인 | 특정 기능 하나가 CPU를 많이 쓰는지 본다 |
| 인스턴스 증설 | 요청을 여러 서버가 나누어 처리하게 한다 |
| 요청 제한 | 서버가 감당할 수 없는 요청이 계속 쌓이지 않게 한다 |

CPU 문제는 단순히 “CPU 사용률이 높다”로 끝나지 않는다. CPU를 오래 쓰는 작업이 있으면 다른 요청이 기다리게 되고, 그 결과 응답 시간이 길어진다.

예를 들어 이미지 변환, 큰 JSON 파싱, 암호화 연산, 큰 반복문은 CPU를 오래 사용할 수 있다. 이런 작업을 HTTP 요청 안에서 바로 처리하면 사용자는 응답을 오래 기다린다. 이때는 작업을 큐에 넣고 별도 워커가 처리하게 하거나, 작업을 작은 단위로 나누는 편이 안전하다.

실무에서 자주 쓰는 완화책은 다음과 같다.

| 상황 | 빠른 조치 | 근본 개선 |
|---|---|---|
| 트래픽 급증 | 인스턴스 수 늘리기 | 미리 부하 테스트하기 |
| 특정 API 과부하 | 요청 수 제한, timeout 적용 | 알고리즘이나 쿼리 개선 |
| 긴 계산 작업 | 작업 큐로 분리 | 비동기 처리, 캐싱 적용 |
| 무한 반복 의심 | 롤백 또는 프로세스 격리 | 반복 종료 조건 점검 |
| 런타임 부하 | Heap, GC 지표 확인 | 객체 생성량 줄이기 |

인스턴스를 늘리면 당장은 CPU 부담이 줄어들 수 있다. 하지만 코드 자체가 비효율적이면 서버를 늘려도 비용만 커진다. 그래서 임시 조치 후에는 알고리즘, DB 쿼리, 캐시, 비동기 처리 구조를 다시 확인해야 한다.

예방을 위해서는 CPU 사용률과 응답 시간을 함께 본다. CPU가 높아도 응답 시간이 안정적이면 정상적인 고부하일 수 있다. 반대로 CPU가 아주 높지 않아도 응답 시간이 길어지면 사용자에게는 장애로 보인다.

```text
CPU usage
load average
run queue length
request latency p95/p99
timeout/error rate
thread pool queue size
```

이 지표들을 함께 보면 CPU Spike가 실제 서비스 지연으로 이어지는지 판단할 수 있다. 특히 `p95`, `p99` latency는 평균보다 중요할 때가 많다. 평균 응답 시간은 괜찮아 보여도 일부 사용자가 매우 느린 응답을 경험하면 운영 장애로 다루어야 한다.

예방 관점에서는 부하 테스트도 중요하다. 평소 트래픽의 2배, 5배가 들어왔을 때 어느 API가 먼저 느려지는지, CPU가 먼저 찬 뒤 메모리가 차는지, thread pool queue가 먼저 밀리는지 미리 알아두면 실제 장애 때 훨씬 빠르게 판단할 수 있다.

리포트:

```text
reports/02-cpu-latency.md
reports/04-scheduling-analysis.md
```

---

## 9. Deadlock: 살아 있지만 앞으로 가지 못하는 프로세스

Deadlock은 프로세스가 죽는 장애가 아니다. 오히려 PID는 살아 있다. 문제는 스레드들이 서로의 자원을 기다리느라 더 이상 앞으로 가지 못한다는 점이다.

식사하는 철학자들 문제를 떠올리면 이번 실험이 더 잘 보인다. 철학자가 포크 두 개를 모두 들어야 밥을 먹을 수 있듯이, 이번 앱의 작업 스레드도 두 자원을 모두 확보해야 일을 끝낼 수 있다. 그런데 한 스레드는 `Shared_Memory_A`를 잡고 `Socket_Pool_B`를 기다리고, 다른 스레드는 `Socket_Pool_B`를 잡고 `Shared_Memory_A`를 기다렸다. 둘 다 하나씩은 가진 상태라 양보하지 않고, 둘 다 상대방이 가진 것을 기다린다.

그래서 Deadlock의 핵심은 “프로세스가 죽었는가”가 아니라 “살아 있는데 더 이상 진행하지 못하는가”다.

### 9.1 실패했던 조건

처음에는 다음 조건으로 시도했다.

```bash
MEMORY_LIMIT=512 CPU_MAX_OCCUPY=100 MULTI_THREAD_ENABLE=true ./scripts/run_agent.sh
```

이 조건에서는 Deadlock 경고는 나왔지만 CPU 보호 종료가 먼저 발생했다. 그래서 Deadlock 확정 증거로는 부족했다.

### 9.2 Deadlock 재현 조건

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

### 9.3 Sleeping 상태와 Deadlock의 차이

`top -H`에서 스레드가 sleeping 상태로 보인다고 해서 곧바로 Deadlock이라고 판단하지 않는다. sleeping은 운영체제가 본 현재 상태이고, Deadlock은 그 상태가 발생한 원인에 대한 해석이다.

쉽게 구분하면 다음과 같다.

```text
sleeping: 지금 CPU를 쓰지 않고 무엇인가를 기다리는 상태
deadlock: 서로가 가진 자원을 기다리느라 더 이상 진행하지 못하는 상태
```

정상 프로그램도 자주 sleeping 상태가 된다. 요청을 기다리는 서버, 파일 I/O를 기다리는 프로세스, 타이머를 기다리는 스레드는 모두 sleeping으로 보일 수 있다. 따라서 sleeping 자체는 장애 증거가 아니라 “현재 실행 중은 아니다”라는 상태 정보에 가깝다.

이번 실험에서 Deadlock으로 판단한 이유는 sleeping 하나 때문이 아니다. 다음 증거를 순서대로 확인했다.

```text
1. monitor.sh로 PID가 계속 살아 있는지 확인했다.
2. monitor.sh로 CPU와 RSS가 오래 변하지 않는지 확인했다.
3. 애플리케이션 로그에서 WAITING/BLOCKED가 마지막 지점인지 확인했다.
4. 로그에서 Thread-1과 Thread-2가 서로 상대방의 자원을 기다리는지 확인했다.
5. snapshot.sh로 ps -L, top -H 상태를 저장했다.
6. 두 번의 snapshot을 비교해 시간이 지나도 같은 대기 상태가 유지되는지 확인했다.
```

진단 관점의 차이는 다음과 같다.

| 구분 | Sleeping 상태 진단 | Deadlock 진단 |
|---|---|---|
| 보는 것 | 스레드가 지금 실행 중인지 | 왜 더 이상 진행하지 못하는지 |
| 주요 도구 | `ps -L`, `top -H` | 앱 로그, 락 로그, thread dump, snapshot |
| 의미 | 기다리는 중일 수 있음 | 순환 대기로 진행 불가 |
| 정상 가능성 | 정상일 수 있음 | 장애 가능성이 높음 |
| 추가로 필요한 증거 | 얼마나 오래 기다리는지 | 누가 어떤 자원을 잡고 누구를 기다리는지 |

정리하면 `ps`와 `top`은 “프로세스가 살아 있지만 실행 중은 아니다”라는 상태를 보여 준다. 애플리케이션 로그의 `LOCK ACQUIRED`, `WAITING`, `BLOCKED`는 “왜 멈췄는가”를 설명한다. 이 둘을 함께 보았기 때문에 이번 상태를 단순 sleeping이 아니라 Deadlock으로 판단했다.

### 9.4 Deadlock 회피 조건

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

### 9.5 실무 대응과 예방

실무에서 Deadlock이 발생하면 프로세스가 살아 있어도 요청 처리가 멈출 수 있다. 모니터링에서는 프로세스가 존재하고 health check도 성공할 수 있지만, 실제 사용자의 요청은 끝나지 않을 수 있다. 그래서 Deadlock은 단순 크래시보다 발견이 늦어지는 경우가 있다.

Deadlock이 위험한 이유는 조용히 서비스를 멈추게 만들 수 있기 때문이다. CPU 사용률이 높게 튀지 않을 수 있고, 에러 로그도 많이 남지 않을 수 있다. 겉으로는 서버가 살아 있는 것처럼 보이지만, 내부 스레드들이 서로 기다리느라 일을 진행하지 못한다.

대표적인 영향은 다음과 같다.

| 영향 | 설명 |
|---|---|
| 요청 무한 대기 | 요청이 끝나지 않고 timeout까지 기다린다 |
| 스레드 고갈 | 요청 처리 스레드가 락 대기에 묶여 새 요청을 처리하지 못한다 |
| 부분 장애 | 특정 기능이나 특정 API만 멈출 수 있다 |
| 탐지 지연 | 프로세스는 살아 있어 단순 health check로는 놓칠 수 있다 |
| 재발 가능성 | 재시작해도 코드의 락 순서가 그대로면 다시 발생할 수 있다 |

Deadlock은 프로세스가 죽지 않을 수 있다. 그래서 발견이 늦어질 수 있다. CPU가 높지 않고 에러 로그도 많지 않은데, 요청이 끝나지 않는 형태로 나타날 수 있다. 따라서 “프로세스가 살아 있다”와 “서비스가 정상 동작한다”를 구분해야 한다.

Deadlock 대응에서 중요한 점은 재시작 전에 증거를 남기는 것이다. Deadlock은 재시작하면 일단 사라질 수 있다. 하지만 어떤 스레드가 어떤 락을 잡고 있었는지도 함께 사라진다. 그래서 가능하면 thread dump나 stack trace를 먼저 남긴다.

즉시 대응은 다음 순서로 진행한다. 목표는 멈춘 인스턴스로 사용자의 요청이 더 들어가지 않게 하고, 원인 분석에 필요한 스레드 상태도 남기는 것이다.

```text
1. 프로세스가 살아 있는지 확인한다.
2. thread dump나 stack trace를 남긴다.
3. 여러 스레드가 같은 락을 기다리는지 확인한다.
4. 문제가 있는 인스턴스를 로드밸런서에서 잠시 제외한다.
5. 증거를 남긴 뒤 재시작하거나 롤백한다.
```

각 단계의 의미는 다음과 같다.

| 단계 | 왜 필요한가 |
|---|---|
| 프로세스 생존 확인 | 죽은 상태인지, 살아 있지만 멈춘 상태인지 구분한다 |
| thread dump 확보 | 어떤 스레드가 어디서 기다리는지 확인한다 |
| lock wait 확인 | 서로의 락을 기다리는 구조인지 본다 |
| 로드밸런서 제외 | 멈춘 인스턴스로 새 요청이 가지 않게 한다 |
| 재시작 또는 롤백 | 서비스를 다시 응답 가능한 상태로 만든다 |

Deadlock은 재시작하면 당장은 풀릴 수 있다. 그러나 재시작은 상태를 초기화할 뿐 락 순서 문제를 고치지는 않는다. 같은 코드 경로가 다시 실행되면 같은 문제가 반복될 수 있다.

근본 해결은 순환 대기가 생기지 않도록 설계를 바꾸는 것이다.

| 예방 방법 | 설명 |
|---|---|
| 락 획득 순서 통일 | 모든 코드가 같은 순서로 락을 잡게 한다 |
| try-lock과 timeout | 오래 기다리지 않고 포기한 뒤 다시 시도한다 |
| critical section 축소 | 락을 잡고 있는 코드를 짧게 만든다 |
| 락 중첩 제거 | 가능하면 락을 여러 개 동시에 잡지 않는다 |
| 공유 상태 축소 | 여러 스레드가 같은 데이터를 동시에 만지지 않게 한다 |
| 코드 리뷰 규칙 | 새 락을 추가할 때 순서와 timeout을 확인한다 |

가장 기본적인 예방책은 락을 잡는 순서를 통일하는 것이다. 예를 들어 어떤 코드는 `UserLock -> OrderLock` 순서로 잡고, 다른 코드는 `OrderLock -> UserLock` 순서로 잡으면 서로 기다리는 상황이 생길 수 있다. 모든 코드가 같은 순서를 지키면 이 가능성을 줄일 수 있다.

`try-lock`과 timeout도 도움이 된다. 두 번째 락을 일정 시간 안에 잡지 못했다면 첫 번째 락을 내려놓고 다시 시도한다. 이렇게 하면 한 스레드가 락을 잡은 채 영원히 기다리는 상황을 줄일 수 있다.

락을 잡고 있는 구간도 짧게 유지해야 한다. 락을 잡은 상태에서 네트워크 호출, 파일 읽기, 긴 계산을 하면 다른 스레드가 오래 기다린다. 락은 공유 데이터를 읽거나 수정하는 짧은 구간에만 사용하는 것이 좋다.

운영 관제에서는 CPU만 보면 Deadlock을 놓칠 수 있다. Deadlock은 CPU를 많이 쓰는 장애가 아니라, 일을 할 수 있는 스레드가 없어지는 장애에 가깝다.

```text
요청 처리 시간이 길어짐
thread pool active count는 높은데 completed task가 늘지 않음
특정 lock wait 시간이 증가
로그가 특정 지점 이후 진행되지 않음
health check는 성공하지만 실제 요청은 timeout
```

이런 신호가 함께 보이면 thread dump를 먼저 남기는 것이 좋다. Deadlock 분석에서 가장 중요한 증거는 “누가 어떤 락을 잡고 있고, 누가 그 락을 기다리는가”이다.

예방을 위해서는 테스트도 필요하다. 단위 테스트만으로는 Deadlock을 찾기 어렵다. 여러 스레드가 동시에 같은 코드를 실행하는 테스트, timeout을 걸어 둔 통합 테스트, 부하 상황에서 요청이 끝까지 완료되는지 확인하는 테스트가 도움이 된다. 락을 새로 추가하는 코드는 코드 리뷰에서 더 신중하게 봐야 한다.

리포트:

```text
reports/03-deadlock.md
```

---

## 10. 장애 리포트 작성법

실험을 끝냈다면 마지막 단계는 리포트다. 좋은 리포트는 길게 쓰는 글이 아니라, 다른 사람이 같은 증거를 보고 같은 결론에 도달할 수 있게 만드는 글이다.

이번 저장소의 리포트는 GitHub Issue 형식을 기준으로 쓴다.

```text
1. Description: 무슨 현상이 일어났는가
2. Evidence & Logs: 어떤 증거가 있는가
3. Root Cause Analysis: 왜 그렇게 판단했는가
4. Workaround & Verification: 무엇을 바꿨고 결과가 어땠는가
```

### 10.1 Description

Description은 사건의 첫 문장이다. 다음 세 가지를 빠뜨리지 않는다.

```text
실행 조건
관측된 현상
현재 판단한 장애 유형
```

예시:

```text
MEMORY_LIMIT=64, CPU_MAX_OCCUPY=100, MULTI_THREAD_ENABLE=false 조건에서 실행 후 Heap이 75MB까지 증가했고, MemoryGuard가 자기 종료를 수행했다. 따라서 커널 OOM Killer가 아니라 앱 내부 메모리 보호 정책에 의한 종료로 판단한다.
```

### 10.2 Evidence & Logs

Evidence에는 파일명과 핵심 라인을 함께 둔다.

```text
evidence/logs/run_20260522_190141.log
evidence/monitor/oom_before_20260522_190136.log
```

그리고 숫자를 말할 때는 변화 방향을 보여 준다.

```text
RSS: 23,832KB -> 49,436KB -> 75,040KB
Heap: 25MB -> 50MB -> 75MB
```

단일 숫자 하나보다 시간에 따른 변화가 훨씬 강한 증거다.

### 10.3 Root Cause Analysis

Root Cause Analysis는 추측을 쓰는 곳이 아니라 증거를 연결하는 곳이다.

```text
Heap이 증가했다.
MEMORY_LIMIT=64를 넘었다.
앱 로그에 Memory limit exceeded가 남았다.
앱 로그에 Self-terminating process가 남았다.
따라서 앱 내부 MemoryGuard 종료로 판단한다.
```

이렇게 원인까지의 징검다리를 보여 주면 읽는 사람이 따라올 수 있다.

### 10.4 Workaround & Verification

조치는 반드시 Before & After로 검증한다.

| 항목 | Before | After |
|---|---|---|
| 변경값 | `MEMORY_LIMIT=64` | `MEMORY_LIMIT=512` |
| 현상 | MemoryGuard 종료 | MemoryGuard 종료 없음 |
| 다음 단계 | CpuWorker 도달 못함 | CpuWorker 도달 |

조치가 완전한 해결인지 임시 회피인지도 구분한다. `MEMORY_LIMIT` 상향이나 `MULTI_THREAD_ENABLE=false`는 실험에서는 유효한 완화책이지만, 근본적으로는 메모리 누수 제거나 락 획득 순서 수정이 필요하다.

### 10.5 피해야 할 표현

| 피해야 할 표현 | 더 나은 표현 |
|---|---|
| 죽은 것 같다 | `Process ended or disappeared`가 기록되었다 |
| 메모리가 많았다 | RSS가 `23,832KB -> 75,040KB`로 증가했다 |
| CPU가 이상했다 | `CpuWorker`가 `CPU Threshold Violated`를 기록했다 |
| 데드락인 듯하다 | 두 스레드가 서로 상대 자원을 기다리고, PID는 살아 있으나 로그가 `WAITING/BLOCKED`에서 멈췄다 |

운영 리포트는 감상을 줄이고 관찰을 늘릴수록 강해진다.

---

## 11. 미션을 진행하면서 개인적으로 궁금했던 것들

Q. 프로세스와 스레드의 차이는?

```text
프로세스는 독립된 주소 공간과 자원을 가진 실행 단위이고, 스레드는 같은 프로세스 안에서 메모리를 공유하는 실행 흐름이다.
```

Q. RSS와 VSZ의 차이는?

```text
RSS는 실제 물리 메모리에 올라온 크기이고, VSZ는 프로세스가 확보한 가상 메모리 크기다.
```

Q. 부모 PID와 자식 PID를 모두 보는 것이 필수인가?

```text
항상 필수는 아니다.
프로그램이 단일 프로세스로만 실행되고 실제 작업도 그 PID 안에서만 일어난다면 하나의 PID만 봐도 된다.
하지만 이번 agent-app-leak처럼 부모 프로세스가 자식 프로세스를 만들고, 실제 CPU나 메모리 사용이 자식 프로세스에서 발생할 수 있는 구조라면 부모와 자식을 함께 봐야 한다.
부모 PID만 보면 앱 전체 RSS, CPU, 스레드 수를 과소평가할 수 있다.
그래서 monitor.sh는 ROOT_PID와 자식 PID를 합쳐 PID_FAMILY로 기록한다.
```

Q. 부모 프로세스와 자식 프로세스는 어떻게 다른가?

```text
부모 프로세스는 다른 프로세스를 만든 쪽이고, 자식 프로세스는 부모에 의해 생성된 실행 단위다.
예를 들어 어떤 서버는 부모 프로세스가 설정을 읽고 포트를 준비한 뒤, 실제 요청 처리는 자식 worker 프로세스에게 맡긴다.
이 경우 부모는 거의 일을 하지 않아 CPU와 RSS가 낮게 보이고, 자식이 실제 자원을 사용할 수 있다.
운영 관제에서 프로세스 트리를 함께 보는 이유가 여기에 있다.
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

Q. 실무 대응에서 말하는 “증거 보존”은 무엇인가?

```text
장애가 발생한 순간의 로그, 메트릭, 프로세스 상태, 스레드 상태를 남겨 두는 것이다.
프로세스를 재시작하면 메모리 상태와 스레드 대기 상태가 사라질 수 있다.
그래서 가능한 경우 재시작 전에 로그, monitor 결과, snapshot, thread dump 같은 자료를 먼저 확보한다.
```

Q. Heap dump는 무엇인가?

```text
Heap dump는 특정 시점에 애플리케이션 Heap 안에 어떤 객체가 얼마나 들어 있는지 저장한 파일이다.
OOM이나 메모리 누수를 분석할 때 사용한다.
예를 들어 같은 타입의 객체가 수백만 개 쌓여 있거나, 이미 끝난 요청의 데이터가 계속 참조되고 있으면 누수 후보가 된다.
```

Q. GC는 무엇인가?

```text
GC는 Garbage Collection의 약자다.
프로그램이 더 이상 사용하지 않는 객체를 런타임이 찾아서 메모리에서 회수하는 작업이다.
GC가 실행된 뒤에도 Heap 사용량이 계속 내려가지 않는다면, 아직 어딘가에서 객체를 참조하고 있을 가능성이 있다.
이 경우 단순히 메모리 limit을 올리는 것보다 객체가 왜 해제되지 않는지 확인해야 한다.
```

Q. 캐시 eviction, TTL, LRU는 무엇인가?

```text
캐시는 자주 쓰는 데이터를 빠르게 꺼내기 위해 메모리에 보관하는 공간이다.
문제는 캐시에 데이터를 무제한으로 넣으면 메모리가 계속 증가할 수 있다는 점이다.
TTL은 일정 시간이 지나면 캐시를 버리는 정책이다.
LRU는 가장 오래 사용되지 않은 데이터를 먼저 버리는 정책이다.
eviction은 이런 규칙에 따라 캐시에서 데이터를 제거하는 동작이다.
```

Q. replica를 늘린다는 것은 무엇인가?

```text
replica는 같은 애플리케이션 인스턴스를 여러 개 띄운 복제본이다.
replica를 늘리면 요청이 여러 프로세스나 여러 컨테이너로 나뉘어 들어간다.
그래서 CPU나 메모리 부담을 한 인스턴스가 전부 떠안지 않게 할 수 있다.
다만 코드 자체에 메모리 누수나 비효율적인 계산이 있으면 replica 증설은 임시 완화책일 뿐이다.
```

Q. autoscaling은 무엇인가?

```text
autoscaling은 트래픽이나 CPU, 메모리 사용량에 따라 replica 수를 자동으로 늘리거나 줄이는 방식이다.
트래픽이 많아지면 인스턴스를 늘리고, 트래픽이 줄어들면 다시 줄인다.
운영자는 peak traffic을 모두 수동으로 예측하지 않아도 되지만, 잘못 설정하면 너무 늦게 늘어나거나 너무 자주 늘었다 줄었다 할 수 있다.
```

Q. rate limit은 무엇인가?

```text
rate limit은 일정 시간 동안 받을 수 있는 요청 수를 제한하는 것이다.
예를 들어 한 사용자에게 초당 10개 요청까지만 허용하는 식이다.
CPU Spike나 특정 API 과부하가 발생했을 때, 서버가 감당할 수 없는 요청이 계속 쌓이는 것을 막는 데 도움이 된다.
rate limit은 사용자를 막기 위한 기능이라기보다, 전체 서비스를 보호하기 위한 안전장치다.
```

Q. timeout은 무엇인가?

```text
timeout은 어떤 작업을 무한히 기다리지 않도록 제한 시간을 두는 것이다.
외부 API 호출, DB 쿼리, 락 획득, 파일 I/O에 timeout이 없으면 하나의 작업이 오래 멈춰 전체 처리 흐름을 막을 수 있다.
timeout은 실패를 빨리 드러내고, 재시도나 우회 처리를 가능하게 한다.
```

Q. backpressure는 무엇인가?

```text
backpressure는 처리하는 쪽이 감당하기 어려울 때, 보내는 쪽의 속도를 늦추게 만드는 제어 방식이다.
예를 들어 작업 큐가 너무 길어지면 새 작업을 잠시 받지 않거나, 요청을 제한하거나, 생산 속도를 낮춘다.
이 장치가 없으면 요청은 계속 들어오는데 처리 속도는 따라가지 못해 메모리, CPU, queue가 함께 무너질 수 있다.
```

Q. 작업 큐와 별도 워커는 무엇인가?

```text
작업 큐는 오래 걸리는 일을 바로 처리하지 않고 줄에 세워 두는 공간이다.
별도 워커는 그 큐에서 작업을 하나씩 꺼내 처리하는 프로세스나 스레드다.
사용자 요청 안에서 큰 계산을 바로 수행하면 응답이 늦어진다.
작업 큐를 쓰면 사용자 요청은 “작업을 접수했다”는 응답을 빠르게 돌려주고, 실제 무거운 처리는 워커가 따로 수행할 수 있다.
```

Q. p95, p99 latency는 무엇인가?

```text
latency는 요청 하나를 처리하는 데 걸린 시간이다.
p95 latency는 전체 요청 중 95%가 이 시간 안에 끝났다는 뜻이다.
p99 latency는 전체 요청 중 99%가 이 시간 안에 끝났다는 뜻이다.
평균 latency가 좋아도 p99가 나쁘면 일부 사용자는 매우 느린 응답을 경험하고 있다는 의미다.
그래서 실무에서는 평균뿐 아니라 p95, p99를 함께 본다.
```

Q. load average와 run queue는 무엇인가?

```text
load average는 실행 중이거나 실행을 기다리는 작업이 평균적으로 얼마나 있었는지 보여 주는 지표다.
run queue는 CPU를 쓰고 싶어서 기다리는 작업의 줄이라고 이해하면 된다.
CPU core 수에 비해 run queue가 계속 길면, 실행하고 싶은 작업은 많은데 CPU가 부족한 상태일 수 있다.
```

Q. thread pool은 무엇인가?

```text
thread pool은 미리 만들어 둔 스레드 묶음이다.
요청이 들어올 때마다 새 스레드를 만들면 비용이 크기 때문에, 준비된 스레드가 작업을 나누어 처리한다.
thread pool의 모든 스레드가 바쁘거나 락을 기다리면 새 요청은 queue에서 기다린다.
그래서 active thread 수, queue size, completed task 수를 함께 보면 병목을 이해하는 데 도움이 된다.
```

Q. thread dump는 무엇인가?

```text
thread dump는 특정 시점에 각 스레드가 어떤 함수에서 실행 중이거나 대기 중인지 보여 주는 자료다.
Deadlock 분석에서 매우 중요하다.
프로세스는 살아 있는데 요청이 끝나지 않는다면, thread dump를 통해 여러 스레드가 같은 락을 기다리는지, 서로의 락을 기다리는지 확인할 수 있다.
```

Q. stack trace는 무엇인가?

```text
stack trace는 현재 실행 흐름이 어떤 함수들을 거쳐 여기까지 왔는지 보여 주는 호출 목록이다.
에러가 발생했을 때는 어디서 실패했는지 알려 주고, Deadlock이나 무응답 상황에서는 스레드가 어느 코드 지점에서 멈췄는지 알려 준다.
```

Q. 로드밸런서에서 인스턴스를 제외한다는 것은 무엇인가?

```text
로드밸런서는 여러 서버나 인스턴스에 요청을 나누어 보내는 장치다.
어떤 인스턴스가 Deadlock이나 과부하로 정상 응답하지 못하면, 그 인스턴스로 새 요청이 가지 않도록 제외할 수 있다.
이렇게 하면 문제가 있는 인스턴스는 조사하거나 재시작하고, 사용자의 요청은 정상 인스턴스로 우회시킬 수 있다.
```

Q. health check가 성공해도 장애일 수 있는가?

```text
그럴 수 있다.
health check는 보통 간단한 경로가 응답하는지만 확인한다.
하지만 실제 사용자 요청은 DB, 외부 API, 락, 큐, 복잡한 계산을 거칠 수 있다.
따라서 health check는 성공하지만 실제 요청은 timeout되는 상황이 가능하다.
운영에서는 단순 생존 확인뿐 아니라 실제 핵심 기능이 정상 동작하는지도 함께 봐야 한다.
```

Q. rollback은 무엇인가?

```text
rollback은 문제가 발생한 배포를 이전 정상 버전으로 되돌리는 것이다.
최근 배포 직후 OOM, CPU Spike, Deadlock이 시작되었다면 새 코드가 원인일 가능성이 있다.
원인을 바로 고치기 어렵고 사용자 영향이 크다면, 먼저 rollback으로 서비스를 안정화한 뒤 원인을 분석한다.
```

Q. 부하 테스트는 무엇인가?

```text
부하 테스트는 실제 운영보다 높은 요청을 미리 보내 시스템이 어디까지 견디는지 확인하는 테스트다.
CPU가 먼저 한계에 도달하는지, 메모리가 먼저 증가하는지, thread pool queue가 먼저 밀리는지 확인할 수 있다.
장애가 난 뒤에야 한계를 알게 되는 것보다, 미리 한계를 알고 알림과 autoscaling 기준을 정하는 편이 안전하다.
```
