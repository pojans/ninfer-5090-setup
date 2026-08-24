# NInfer-4090 + Oh My Pi for WSL2

One-command installation of a local Qwen3.8-27B coding stack on an NVIDIA RTX 4090:

- NInfer compiled natively for Linux/WSL and Ada `sm_89`
- CUDA Toolkit 13.1
- the verified Qwen3.8-27B `.ninfer` model
- Oh My Pi (OMP) running inside WSL
- a `ninfer` command that starts the service and opens OMP

This installer deliberately uses a conservative WSL profile rather than NInfer's maximum-context shipping profile. The goal is repeatable daily use on a 24 GB RTX 4090 even when Windows and WSL GPU-memory availability drifts.

## Install

Run this inside an Ubuntu WSL2 terminal:

```sh
curl -fsSL https://raw.githubusercontent.com/pojans/ninfer-4090-setup/main/install.sh | sh
```

The installer provisions everything, starts NInfer, waits for the API to become healthy, and launches the OMP TUI with `Qwen3.8 27B (NInfer) · xhigh` selected.

To provision without starting NInfer or opening OMP:

```sh
curl -fsSL https://raw.githubusercontent.com/pojans/ninfer-4090-setup/main/install.sh | sh -s -- --no-launch
```

## Requirements

- Windows 11 with WSL2
- an Ubuntu WSL distribution with `apt-get`
- NVIDIA GeForce RTX 4090 with 24 GB VRAM
- a current Windows NVIDIA driver with WSL CUDA support
- at least 30 GB free under the WSL home directory for a clean installation
- internet access to GitHub, NVIDIA's package repository, and Hugging Face
- `sudo` access inside WSL

The CUDA toolkit is installed inside WSL. Do not install a Linux display driver in WSL; GPU access is supplied by the Windows NVIDIA driver.

## Daily use

```sh
ninfer
```

`ninfer` checks `http://127.0.0.1:8080/v1/models`. If the endpoint is not healthy, it starts `ninfer-serve` in the background and waits up to ten minutes for model loading. It then launches OMP in the same terminal.

Other commands:

```sh
ninfer serve    # Start the service without opening OMP
ninfer status   # Show endpoint state and GPU memory usage
ninfer stop     # Stop NInfer and release its VRAM
ninfer --help   # Show command help
```

Service logs are written to:

```text
~/.local/state/ninfer/server.log
```

## What the installer does

1. Rejects native Windows, native Linux, non-RTX-4090 GPUs, and insufficient disk space.
2. Installs missing packages: `build-essential`, `cmake`, `ninja-build`, `git`, `curl`, `ca-certificates`, and `procps`.
3. Installs the NVIDIA WSL CUDA 13.1 toolkit if `/usr/local/cuda-13.1/bin/nvcc` is missing.
4. Clones the `rtx4090-port` branch of [`sergiuszm/ninfer-4090`](https://github.com/sergiuszm/ninfer-4090) and pins a fresh checkout to verified commit `981b685ea2124fdaed023123d2e63fd29d529ab8`.
5. Builds `ninfer-serve` in Release mode with Ninja and all available CPU cores.
6. Downloads the model from pinned Hugging Face revision `18dfc887423fa5aabf3cb56fac41490e462b3fab`.
7. Verifies the model's exact size: `18,210,531,328` bytes (16.96 GiB). Interrupted downloads resume with HTTP ranges.
8. Installs `~/.local/bin/ninfer` and registers `~/.local/bin` in `~/.bashrc`.
9. Installs the prebuilt Linux x64 OMP v18.0.4 binary to `~/.local/bin/omp`.
10. Writes the NInfer provider to `~/.omp/agent/models.yml` and selects it in `~/.omp/agent/config.yml`.
11. Starts the service and launches OMP unless `--no-launch` was passed.

## Exact NInfer runtime profile

The generated `ninfer` command launches this server:

```sh
ninfer-serve qwen3_8_27b.ninfer \
  --host 127.0.0.1 \
  --port 8080 \
  --max-context 114688 \
  --kv-capacity 114688 \
  --max-concurrency 1 \
  --max-pending-requests 16 \
  --pending-timeout-ms 600000 \
  --prefill-chunk 512 \
  --kv-dtype int8 \
  --spec mtp \
  --draft-tokens 3 \
  --lm-head-draft \
  --no-cuda-graph
```

### Flag-by-flag explanation

| Flag | Effect | Why this profile uses it |
|---|---|---|
| `qwen3_8_27b.ninfer` | Loads the official groupwise `.ninfer` Qwen3.8-27B artifact. | The artifact contains the model identity and the target/MTP weights expected by this NInfer fork. |
| `--host 127.0.0.1` | Listens only on the WSL loopback interface. | OMP runs in the same WSL distribution. Local binding avoids exposing an unauthenticated model API to the LAN. |
| `--port 8080` | Serves the API on TCP port 8080. | Matches OMP's configured base URL, `http://127.0.0.1:8080/v1`. |
| `--max-context 114688` | Caps each request's logical sequence length at 114,688 tokens. | Leaves practical VRAM margin below the RTX 4090 fork's measured INT8 ceiling. This is intentional WSL stability headroom, not the largest context NInfer can theoretically fit. |
| `--kv-capacity 114688` | Allocates a shared Main Text KV page pool for 114,688 tokens. | Equal to the per-request ceiling. With one admitted request, the active session can use the entire pool without relying on automatic sizing from momentary free VRAM. |
| `--max-concurrency 1` | Admits one active generation request. | OMP is used as one interactive coding session. One lane minimizes fixed sequence state and avoids extra graph/lane allocations. The upstream fork measures concurrency 2 as useful, but it costs additional VRAM and prefill still serializes. |
| `--max-pending-requests 16` | Allows 16 additional generation requests to wait behind the active request. | Prevents short bursts from immediately returning overload errors while keeping the queue bounded. Total generation lifetime capacity is active plus pending requests. |
| `--pending-timeout-ms 600000` | Gives preparation and admission ten minutes before returning `request_queue_timeout`. | Deep prompts can spend longer than the server's 30-second default waiting behind prefill. The longer deadline is safer for agent/tool workloads. |
| `--prefill-chunk 512` | Processes prompt prefill in 512-token units. The value must be a positive multiple of 128. | A smaller conservative chunk bounds each prefill unit and its planned scratch requirement. Upstream benchmarks usually use 1024; 512 is the profile verified stable under WSL on this machine. |
| `--kv-dtype int8` | Stores the KV cache in group-64 INT8 form. | Higher cache precision than the fork's 4-bit and 2-bit E8 modes, at the cost of less maximum context. This profile chooses precision and predictable behavior over the 262K compressed-KV headline. |
| `--spec mtp` | Enables Multi-Token Prediction speculative decoding. | NInfer can draft several tokens and verify them with the target model, substantially increasing decode throughput on predictable output such as code. |
| `--draft-tokens 3` | Gives MTP three draft positions. | MTP3 is the fork's measured Qwen3.8-27B profile. Acceptance varies by content: structured code tends to accept more drafts than prose. |
| `--lm-head-draft` | Selects the optimized proposal head for speculative decoding. | Avoids the full proposal head and is the measured companion to MTP3. It requires a speculative backend. |
| `--no-cuda-graph` | Disables CUDA Graph decode replay. | Trades some decode speed for lower graph-allocation/capture sensitivity. Windows and WSL consume variable portions of the shared 4090 VRAM; disabling graphs was the reliable choice for this daily-driver profile. |

## Optimizations enabled by the NInfer fork

The installer does not implement the GPU kernels; it selects a verified build and runtime profile from the RTX 4090 fork. Relevant engine optimizations include:

### Native Ada target

The fork targets NVIDIA Ada `sm_89`, the RTX 4090's compute capability. It uses the groupwise-integer path rather than Blackwell-only NVFP4/W4A4 kernels.

### Ada-retuned INT8 attention prefill

The fork contains an `sm_89`-specific INT8 attention-prefill schedule using the Ada register budget and a retuned producer/consumer layout. The upstream project reports a 30% kernel gain on the tested 64K append shape and a 5-7% serving-prefill gain at 88K-128K. Those figures describe the fork's controlled benchmarks, not a guarantee for this conservative WSL profile.

### Paged KV cache

KV state is allocated in pages rather than one monolithic per-session buffer. The page pool is shared across admitted slots, supports compatible-prefix reuse, and is planned before the server begins listening. An oversized explicit profile therefore fails during startup instead of failing partway through a request.

### Compatible-prefix reuse

Prefix reuse is enabled by default because this launcher does not pass `--no-prefix-reuse`. A later request with a compatible retained prefix can avoid recomputing that prefix, which is valuable for repeated agent conversations and tool turns.

### MTP3 speculative decoding

MTP proposes three future tokens and the target model verifies them. The fork reports 148.6 tokens/s at 81% draft acceptance on its code-generation benchmark versus 50.5 tokens/s with speculation disabled. That benchmark used CUDA Graphs, greedy decoding, INT8 KV, and a 1024-token prefill chunk; it should not be treated as a measured number for this installer's `--no-cuda-graph` WSL profile.

### Optimized proposal head

`--lm-head-draft` loads the smaller optimized proposal-head path selected for the published MTP measurements instead of the full proposal head. This reduces the speculative runtime's resident profile.

### Fixed startup memory planning

NInfer plans weights, sequence state, prefill scratch, speculative state, KV pages, and optional CUDA Graph allowance before serving. This profile supplies an explicit KV capacity instead of deriving capacity from free VRAM, so Windows-side VRAM drift does not silently change the available context from one launch to the next.

## Deliberate reliability choices

This setup is intentionally different from the fork's maximum-capacity examples.

### 114,688 tokens instead of 172K or 262K

The fork documents approximately 172,032 tokens as the measured text-only MTP3 ceiling with INT8 KV and 262,144 tokens with `rk4v4-e8`. Those profiles run close to the 24 GB limit. WSL shares the physical GPU with Windows desktop applications, so reported free VRAM can change between launches.

The installed 114,688-token profile sacrifices theoretical context for enough margin to start reliably. OMP is told the same `contextWindow`, preventing it from sending oversized prompts.

### INT8 KV instead of E8 4-bit KV

The E8 `rk4v4-e8` mode fits the model's full native 262K context and the fork reports exact retrieval through 260K in its tests. It also reports a 5.7% decode cost and 1-2% prefill cost against INT8 at matched depth. This installer stays with INT8 because 114,688 tokens are sufficient for the intended coding workflow and the less compressed cache is the conservative quality choice.

### CUDA Graphs disabled

CUDA Graphs reduce repeated decode-launch overhead and are enabled in the fork's headline benchmarks. They also require a graph family and reserved driver allowance for reachable batch shapes. `--no-cuda-graph` removes that source of startup sensitivity. This is a reliability tradeoff, not the peak-throughput configuration.

### One active request

`--max-concurrency 2` is measured upstream at roughly 1.5x aggregate decode throughput and costs about 390 MiB for the second lane under the measured graph-enabled profile. It does not make a single OMP request faster, and prompt prefill remains serialized, so this installer keeps one lane.

### Text-only allocations

The launcher omits `--vision`. NInfer therefore does not load the vision tower, vision scratch workspace, or media request-transient allocation. OMP's model declaration similarly advertises text input only. This preserves VRAM for context and speculative decoding.

## Relevant defaults intentionally left enabled

| Behavior | Result |
|---|---|
| Thinking | Enabled. The launcher does not pass `--no-thinking`. |
| Closed-turn reasoning retention | Disabled. The launcher does not pass `--preserve-thinking`, so prior hidden reasoning is not fed back into later prompts. |
| Compatible-prefix reuse | Enabled. The launcher does not pass `--no-prefix-reuse`. |
| Vision | Disabled because `--vision` is absent. |
| Device | CUDA device 0 because `--device` is absent. |
| Server default output limit | 8,192 tokens when the request omits a limit. OMP is configured with the same `maxTokens: 8192`. |
| Authentication | None. This is safe only because the listener is bound to `127.0.0.1`. |

## OMP configuration

The installer writes this provider:

```yaml
providers:
  llama.cpp:
    baseUrl: http://127.0.0.1:8080/v1
    api: openai-completions
    auth: none
    models:
      - id: qwen3.8-27b
        name: Qwen3.8 27B (NInfer)
        reasoning: true
        input:
          - text
        tokenizer: qwen3
        contextWindow: 114688
        maxTokens: 8192
```

OMP's default role is:

```yaml
modelRoles:
  default: llama.cpp/qwen3.8-27b:xhigh
```

Important details:

- `baseUrl` ends in `/v1`, matching NInfer's OpenAI-compatible route prefix.
- `api: openai-completions` uses OMP's completions-compatible adapter. It avoids Responses-only request fields that this NInfer build rejects.
- `auth: none` matches the local unauthenticated server.
- `reasoning: true` exposes reasoning controls to OMP.
- `:xhigh` selects the model's extra-high reasoning effort for OMP's default role.
- `contextWindow` exactly matches `--max-context`.
- `maxTokens` matches NInfer's default 8,192-token output ceiling.

## Installation layout

```text
~/projects/ninfer-4090/                  NInfer source checkout
~/projects/ninfer-4090/build/apps/       compiled binaries
~/projects/ninfer-4090/models/           16.96 GiB model
~/.local/bin/ninfer                      daily launcher/service controller
~/.local/bin/omp                         OMP Linux x64 binary
~/.local/state/ninfer/server.log         server log
~/.local/state/ninfer/server.pid         last background PID
~/.omp/agent/models.yml                  local provider declaration
~/.omp/agent/config.yml                  OMP default role
```

## Idempotence and pinning

The installer is safe to re-run:

- already installed Debian packages are skipped;
- CUDA 13.1 is skipped when its `nvcc` is executable;
- an existing NInfer Git checkout is reused rather than reset;
- an existing server binary is not rebuilt;
- the model is skipped only when its exact expected byte size is present;
- partial model downloads resume;
- an existing OMP binary is reused;
- the PATH marker is appended to `.bashrc` once;
- `models.yml` is replaced deterministically;
- `config.yml` is preserved except for the NInfer default role and `setupVersion`.

Fresh installs pin the NInfer commit, Hugging Face model revision, model size, CUDA toolkit line, and OMP version. This avoids an unreviewed upstream change silently producing a different machine.

Re-running the installer intentionally regenerates `~/.local/bin/ninfer` and `~/.omp/agent/models.yml`. Make permanent profile changes in this repository's `install.sh`, not only in those generated files.

## Troubleshooting

### `nvidia-smi was not found in WSL`

Install or update the Windows NVIDIA driver, then restart WSL from PowerShell:

```powershell
wsl --shutdown
```

Open Ubuntu again and verify:

```sh
nvidia-smi
```

Do not install a separate Linux NVIDIA display driver inside WSL.

### Service does not become ready

Inspect the server log:

```sh
tail -n 100 ~/.local/state/ninfer/server.log
```

Then stop any failed process and retry:

```sh
ninfer stop
ninfer serve
```

Common causes are another process already using port 8080, insufficient free VRAM, or a damaged/incomplete model file.

### Port 8080 is already in use

Identify the listener:

```sh
ss -ltnp | grep ':8080'
```

Stop the conflicting service, then run `ninfer` again. The OMP configuration and launcher both expect port 8080.

### OMP opens with the wrong model

Verify:

```sh
grep -A2 '^modelRoles:' ~/.omp/agent/config.yml
cat ~/.omp/agent/models.yml
```

The default must be `llama.cpp/qwen3.8-27b:xhigh`, and the provider URL must be `http://127.0.0.1:8080/v1`.

### Release GPU memory

```sh
ninfer stop
```

The service is intentionally persistent across OMP sessions so reopening OMP does not reload 16.96 GiB of weights each time.

## Source documentation

- [NInfer RTX 4090 fork](https://github.com/sergiuszm/ninfer-4090)
- [Verified NInfer revision](https://github.com/sergiuszm/ninfer-4090/tree/981b685ea2124fdaed023123d2e63fd29d529ab8)
- [NInfer serving documentation](https://github.com/sergiuszm/ninfer-4090/blob/981b685ea2124fdaed023123d2e63fd29d529ab8/docs/serving.md)
- [NInfer CLI and memory-planning documentation](https://github.com/sergiuszm/ninfer-4090/blob/981b685ea2124fdaed023123d2e63fd29d529ab8/docs/cli.md)
- [Qwen3.8-27B NInfer artifact](https://huggingface.co/neroued/Qwen3.8-27B-NInfer)
- [Oh My Pi](https://github.com/can1357/oh-my-pi)
