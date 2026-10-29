# jetson-moe-gpu-stabilizer

[English](README.md)

MoE expert 오프로드(`--cpu-moe`, `--n-cpu-moe`)를 쓰는 llama.cpp 프로세스가 추론하는 동안에만 Jetson GPU 클럭 하한을 올린다. 마지막 decode 호출이 끝나고 1초가 지나면 하한을 최저로 되돌린다. 감지는 `libllama.so`에 붙인 eBPF uprobe로 하므로 llama.cpp 코드는 고치지 않는다.

## 배경

`--cpu-moe`에서는 토큰마다 GPU 작업(attention, router, shared expert)과 CPU 작업(메모리나 NVMe에서 읽은 routed expert 계산)이 번갈아 실행된다. CPU가 계산하는 동안 GPU는 쉬므로 devfreq 거버너(`nvhost_podgov`)는 GPU 부하를 약 27%로 보고 클럭을 최저로 둔다. Orin Nano에서 최저는 306 MHz다. 그런데 GPU 구간도 토큰마다 지나야 하는 경로에 있어서, 클럭이 낮으면 토큰 시간이 그만큼 늘어난다.

`min_freq`는 하한만 올린다. `jetson_clocks`는 CPU와 메모리 클럭까지 고정하는데, 이 측정에서는 평균 속도는 비슷했지만 실행마다 속도 편차가 약 두 배로 커졌다.

## 측정 결과

Jetson Orin Nano Super 8GB, JetPack 6.2(L4T r36), MAXN_SUPER, 헤드리스. 모델은 Qwen3.6-35B-A3B MXFP4 GGUF로, 메모리보다 크며 `--cpu-moe`로 expert를 NVMe에서 mmap했다. 실제 프롬프트 12개로 각 256토큰을 greedy 생성했다.

| GPU 하한 | decode 평균 | 실행 간 CV | 추론 중 전력 | 토큰당 에너지 |
|---|---:|---:|---:|---:|
| 없음 (거버너 기본, 실제로는 306 MHz) | 2.73 tok/s | 약 11% | 8.05 W | 2.95 J |
| 추론 중 1020 MHz | 3.37 tok/s (×1.24) | 약 11% | 9.63 W | 2.86 J |

dense 모델은 GPU가 계속 바빠서 거버너가 이미 950 MHz 근처로 올린다. 하한을 걸어도 속도 차이는 0~1%였다. 이 서비스는 MoE 오프로드 플래그로 시작한 프로세스에만 반응하므로 dense 모델에는 개입하지 않는다.

보드 한 대와 모델 하나에서 얻은 수치다. 모델, 오프로드 비율, 전원 모드가 달라지면 이득도 달라진다.

## 동작 방식

1. `bpftrace`로 `MOE_GPU_LIBS`에 해당하는 모든 라이브러리의 `llama_decode`, `llama_process`, `llama_synchronize`에 uprobe와 uretprobe를 건다. 최근 llama-server와 llama-bench는 비동기 함수 `llama_process`를 호출하고 작업이 `llama_synchronize`에서 끝날 수 있어서, 세 함수 모두를 추론 활동으로 본다.
2. 프로세스 명령줄에 `--cpu-moe`, `-cmoe`, `--n-cpu-moe`, `-ncmoe` 중 하나가 있을 때만 센다.
3. 첫 호출에서 GPU devfreq의 `min_freq`를 활성 하한으로 올린다. 기본값은 사용할 수 있는 최고 주파수다. 진행 중인 호출 없이 `MOE_GPU_HOLD_S`(기본 1초)가 지나면 최저 주파수로 되돌린다.
4. 5초마다 대상 라이브러리를 다시 확인한다. uprobe는 이전 inode에 묶여 있으므로, `libllama.so`를 다시 빌드하거나 새로 빌드하면 새로 붙인다.

쓰는 값은 `min_freq` 하나다. `max_freq`, 거버너, CPU·메모리 클럭은 건드리지 않는다. 서비스가 끝날 때는 하한을 최저로 되돌린다.

## 요구 사항

- `/sys/class/devfreq`에 GPU devfreq 노드가 있는 Jetson (확인한 환경: Orin Nano Super 8GB, JetPack 6.2.3)
- `bpftrace`(없으면 설치 스크립트가 apt로 설치), Python 3, root 권한
- 공유 라이브러리(`libllama.so`, 기본 빌드)로 빌드한 llama.cpp, 또는 심볼이 남아 있는 실행 파일

## 설치

```bash
git clone https://github.com/gnu-gnu/jetson-moe-gpu-stabilizer
cd jetson-moe-gpu-stabilizer
python3 moe-gpu-stabilizer --check   # root 불필요: 찾은 devfreq 노드, 주파수, 라이브러리를 출력
sudo ./install.sh
```

`--check`가 `libraries none found`를 출력하면 `/etc/default/moe-gpu-stabilizer`에 `MOE_GPU_LIBS`를 지정하고 서비스를 재시작한다.

## 설정

설정 파일은 `/etc/default/moe-gpu-stabilizer`이며, 고친 뒤에는 서비스를 재시작해야 한다.

| 변수 | 기본값 | 의미 |
|---|---|---|
| `MOE_GPU_LIBS` | `/usr/local/lib/libllama.so:/usr/lib/libllama.so:/home/*/llama.cpp*/build/bin/libllama.so:/home/*/src/llama.cpp*/build/bin/libllama.so` | 추적할 경로 또는 glob, 콜론으로 구분 |
| `MOE_GPU_FLOOR_MHZ` | `0` (최고 주파수) | 추론 중 하한. 지원하는 주파수 단계로 내림 |
| `MOE_GPU_HOLD_S` | `1.0` | 마지막 호출이 끝난 뒤 하한을 유지하는 시간(초) |
| `MOE_GPU_MOE_FLAGS` | `--cpu-moe,-cmoe,--n-cpu-moe,-ncmoe` | MoE 오프로드 프로세스로 볼 명령줄 플래그 |
| `MOE_GPU_DEVFREQ` | 자동 (`/sys/class/devfreq/*.gpu`) | GPU devfreq 디렉터리 |

## 동작 확인

```bash
journalctl -u moe-gpu-stabilizer -f
cat /sys/class/devfreq/17000000.gpu/min_freq
```

`--cpu-moe` 서버에 요청을 보내면 로그에 `floor 1020 MHz (pid … inference)`가 찍힌다. 생성이 끝나고 약 1초 뒤에는 `floor 306 MHz (idle)`가 찍힌다. 요청 없이 떠 있는 서버, dense 모델, MoE 오프로드 플래그가 없는 서버에서는 하한이 올라가지 않는다.

## 한계

- llama.cpp만 감지한다. 외부에 공개된 함수 이름으로 찾기 때문에 다른 런타임에는 별도 probe가 필요하다.
- MoE 오프로드 여부는 명령줄 플래그로 판단한다. `--override-tensor`처럼 다른 방식으로 expert를 오프로드하는 프로세스는, 그 플래그를 `MOE_GPU_MOE_FLAGS`에 추가하지 않으면 감지하지 못한다.
- `jetson_clocks`나 `min_freq`를 쓰는 다른 도구와 함께 쓰지 않는다.
- 보드 한 종류, JetPack 한 버전에서만 확인했다.

## 제거

```bash
sudo ./uninstall.sh
```

## 라이선스

MIT
