# jetson-moe-gpu-stabilizer

[한국어](README.ko.md)

Raises the Jetson GPU clock floor **only while** a llama.cpp process with MoE expert offload (`--cpu-moe`, `--n-cpu-moe`) is running inference, and drops it back to the minimum one second after the last decode call returns. Detection uses eBPF uprobes on `libllama.so`, so nothing in llama.cpp has to change.

## Why

With `--cpu-moe`, every token alternates between GPU work (attention, router, shared expert) and CPU work (routed experts read from memory or NVMe). The GPU sits idle while the CPU computes, so the devfreq governor (`nvhost_podgov`) sees about 27% GPU load and keeps the clock at its minimum, 306 MHz on Orin Nano. The GPU part is still on the per-token critical path, so the low clock directly lengthens every token.

Setting `min_freq` raises the floor without pinning everything the way `jetson_clocks` does. `jetson_clocks` also fixes the CPU and memory clocks; in our runs it gave a similar mean speed with about twice the run-to-run variation.

## Measured effect

Jetson Orin Nano Super 8GB, JetPack 6.2 (L4T r36), MAXN_SUPER, headless. Qwen3.6-35B-A3B MXFP4 GGUF (larger than RAM) with `--cpu-moe`, experts memory-mapped from NVMe. 12 real prompts, 256 generated tokens each, greedy decoding.

| GPU floor | decode mean | run-to-run CV | busy power | energy per token |
|---|---:|---:|---:|---:|
| none (governor default, 306 MHz in practice) | 2.73 tok/s | ~11% | 8.05 W | 2.95 J |
| 1020 MHz while inferring | 3.37 tok/s (×1.24) | ~11% | 9.63 W | 2.86 J |

Dense models keep the GPU busy, the governor already runs them near 950 MHz, and the floor changed their speed by 0–1%. The service leaves them alone anyway, because it only reacts to processes started with a MoE-offload flag.

These numbers come from one board and one model. Other models, offload splits and power modes will give a different gain.

## How it works

1. `bpftrace` attaches uprobes and uretprobes to `llama_decode`, `llama_process` and `llama_synchronize` in every library matched by `MOE_GPU_LIBS`. Recent llama-server and llama-bench builds call `llama_process`, which is asynchronous, and the work can finish in `llama_synchronize`, so all three count as activity.
2. A call counts only if the process command line contains one of `--cpu-moe`, `-cmoe`, `--n-cpu-moe` or `-ncmoe`.
3. On the first call, the GPU devfreq `min_freq` is set to the active floor, by default the highest available frequency. When no call has been running for `MOE_GPU_HOLD_S` (1 s by default), it is set back to the lowest frequency.
4. Every 5 s the matched libraries are re-checked. A rebuilt or newly built `libllama.so` gets a fresh attachment, because uprobes stay bound to the old inode.

Only `min_freq` is written. `max_freq`, the governor, the CPU and the memory clocks stay untouched. On exit the service restores the lowest floor.

## Requirements

- Jetson with a GPU devfreq node under `/sys/class/devfreq` (tested: Orin Nano Super 8GB, JetPack 6.2.3)
- `bpftrace` (the installer adds it with apt if missing), Python 3, root
- llama.cpp built as a shared library (`libllama.so`, the default) or a binary that still has its symbols

## Install

```bash
git clone https://github.com/gnu-gnu/jetson-moe-gpu-stabilizer
cd jetson-moe-gpu-stabilizer
python3 moe-gpu-stabilizer --check   # no root needed: shows the devfreq node, frequencies and libraries it found
sudo ./install.sh
```

If `--check` reports `libraries none found`, set `MOE_GPU_LIBS` in `/etc/default/moe-gpu-stabilizer` and restart the service.

## Configuration

`/etc/default/moe-gpu-stabilizer`. Restart the service after editing it.

| Variable | Default | Meaning |
|---|---|---|
| `MOE_GPU_LIBS` | `/usr/local/lib/libllama.so:/usr/lib/libllama.so:/home/*/llama.cpp*/build/bin/libllama.so:/home/*/src/llama.cpp*/build/bin/libllama.so` | colon-separated paths or globs to trace |
| `MOE_GPU_FLOOR_MHZ` | `0` (highest available) | floor while inference runs; rounded down to an available step |
| `MOE_GPU_HOLD_S` | `1.0` | seconds to keep the floor after the last call returns |
| `MOE_GPU_MOE_FLAGS` | `--cpu-moe,-cmoe,--n-cpu-moe,-ncmoe` | command-line flags that mark a MoE-offload process |
| `MOE_GPU_DEVFREQ` | auto (`/sys/class/devfreq/*.gpu`) | GPU devfreq directory |

## Check that it works

```bash
journalctl -u moe-gpu-stabilizer -f
cat /sys/class/devfreq/17000000.gpu/min_freq
```

Start a request against a `--cpu-moe` server. The log shows `floor 1020 MHz (pid … inference)`, then `floor 306 MHz (idle)` about one second after generation ends. An idle server, a dense model, or a server without a MoE-offload flag does not raise the floor.

## Limitations

- Only llama.cpp is detected, by its exported function names. Other runtimes need their own probes.
- MoE offload is detected from command-line flags. A process that offloads experts another way, for example with `--override-tensor`, is not detected unless you add its flag to `MOE_GPU_MOE_FLAGS`.
- Do not run it together with `jetson_clocks` or another tool that writes `min_freq`.
- Tested on one board and one JetPack release.

## Uninstall

```bash
sudo ./uninstall.sh
```

## License

MIT
