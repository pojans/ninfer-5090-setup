# NInfer-5090 + Oh My Pi for WSL2

One-command installation of a local Qwen3.8-27B coding stack on an NVIDIA RTX 5090:

- NInfer built from the canonical [`Neroued/ninfer`](https://github.com/Neroued/ninfer) repository for Blackwell `sm_120a`;
- CUDA Toolkit 13.1;
- the published Qwen3.8-27B NVFP4 `.ninfer` artifact;
- Oh My Pi (OMP) running inside WSL;
- a `ninfer` command that starts the API and opens OMP.

This repository is the RTX 5090 counterpart to [`pojans/ninfer-4090-setup`](https://github.com/pojans/ninfer-4090-setup). It uses the upstream NInfer runtime and the Blackwell NVFP4 artifact; it is not an Ada/RTX 4090 fork.

## Install

Run this inside an Ubuntu WSL2 terminal:

```sh
curl -fsSL https://raw.githubusercontent.com/pojans/ninfer-5090-setup/main/install.sh | sh
```

The installer provisions everything, starts NInfer, waits for the API to become healthy, and launches OMP with `Qwen3.8 27B NVFP4 (NInfer) · xhigh` selected.

To provision without starting NInfer or opening OMP:

```sh
curl -fsSL https://raw.githubusercontent.com/pojans/ninfer-5090-setup/main/install.sh | sh -s -- --no-launch
```

## Requirements

- Windows 11 with WSL2;
- an Ubuntu WSL distribution with `apt-get`;
- NVIDIA GeForce RTX 5090 with 32 GB VRAM;
- a current Windows NVIDIA driver with WSL CUDA support;
- at least 30 GB free under the WSL home directory for a clean installation;
- internet access to GitHub, NVIDIA's package repository, and Hugging Face;
- `sudo` access inside WSL.

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
ninfer stop     # Stop NInfer and release VRAM
ninfer --help   # Show command help
```

The service log is written to `~/.local/state/ninfer/server.log`.

## What the installer does

1. Rejects native Windows, native Linux, non-RTX-5090 GPUs, and insufficient disk space.
2. Installs missing build packages: `build-essential`, `cmake`, `ninja-build`, `git`, `curl`, `ca-certificates`, `procps`, `pkg-config`, FFmpeg development headers, and libcurl development headers.
3. Installs the NVIDIA WSL CUDA 13.1 toolkit if `/usr/local/cuda-13.1/bin/nvcc` is missing.
4. Clones [`Neroued/ninfer`](https://github.com/Neroued/ninfer) and pins a fresh checkout to commit [`6e8b2e2ad5d53597c3ba8e7989f9546d40b921fc`](https://github.com/Neroued/ninfer/commit/6e8b2e2ad5d53597c3ba8e7989f9546d40b921fc).
5. Builds the Release binaries with CMake and Ninja.
6. Downloads `qwen3_8_27b_nvfp4.ninfer` from pinned Hugging Face revision [`3b84117e0fd258b45bd79778ec8d8f27a4ab3d56`](https://huggingface.co/neroued/Qwen3.8-27B-nvfp4-NInfer/commit/3b84117e0fd258b45bd79778ec8d8f27a4ab3d56).
7. Verifies the artifact's exact size: `21,492,695,040` bytes (20.02 GiB) and SHA-256: `bb3360522a06e136e0367f5703414d26272b7285c8a6ab6194135c17dbd81b32`.
8. Installs `~/.local/bin/ninfer` and registers `~/.local/bin` in `~/.bashrc`.
9. Installs the prebuilt Linux x64 OMP v18.0.4 binary to `~/.local/bin/omp`.
10. Writes the NInfer provider to `~/.omp/agent/models.yml` and selects it in `~/.omp/agent/config.yml`.
11. Starts the service and launches OMP unless `--no-launch` was passed.

## Runtime profile

The generated `ninfer` command launches this text-only server profile:

```sh
ninfer-serve qwen3_8_27b_nvfp4.ninfer \
  --host 127.0.0.1 \
  --port 8080 \
  --max-context 240000 \
  --kv-capacity 240000 \
  --max-concurrency 2 \
  --max-pending-requests 16 \
  --pending-timeout-ms 600000 \
  --prefill-chunk 1024 \
  --kv-dtype fp8 \
  --device-state-slots 2 \
  --host-state-slots 8 \
  --host-kv-mib 8192 \
  --spec mtp \
  --draft-tokens 3 \
  --lm-head-draft \
  --preserve-thinking
```

The profile follows the current NInfer README profile for a 32 GB RTX 5090:

- `--max-context` and `--kv-capacity` provide a fixed 240,000-token per-request ceiling and shared Main Text KV pool;
- FP8 KV reduces device-memory pressure while the host state slots and 8 GiB host KV allowance provide additional cache capacity;
- two active request lanes allow modest batching while keeping startup memory bounded;
- MTP3 plus the optimized draft head improves decode throughput on suitable workloads;
- CUDA Graph decode remains enabled for the Blackwell profile;
- `--preserve-thinking` keeps closed-turn reasoning available to later agent turns;
- `--vision` is omitted so the interactive coding profile does not reserve Vision allocations;
- loopback binding keeps the unauthenticated API local to the WSL instance.

The 240,000-token setting is the upstream documented profile and is more aggressive than the original 131,072-token setup. Actual available VRAM still depends on Windows GPU usage and WSL memory state; if startup fails, inspect `~/.local/state/ninfer/server.log` and stop other GPU workloads before retrying.

## OMP configuration

The installer writes:

```yaml
providers:
  llama.cpp:
    baseUrl: http://127.0.0.1:8080/v1
    api: openai-completions
    auth: none
    models:
      - id: qwen3.8-27b
        name: Qwen3.8 27B NVFP4 (NInfer)
        reasoning: true
        input:
          - text
        tokenizer: qwen3
        contextWindow: 240000
        maxTokens: 8192
```

The default OMP role is `llama.cpp/qwen3.8-27b:xhigh`. The provider uses the public model ID embedded in the artifact and the OpenAI Completions-compatible adapter expected by this local server.

## Installation layout

```text
~/projects/ninfer-5090/                  NInfer source checkout
~/projects/ninfer-5090/build/apps/       compiled binaries
~/projects/ninfer-5090/models/           20.02 GiB NVFP4 model
~/.local/bin/ninfer                      daily launcher/service controller
~/.local/bin/omp                         OMP Linux x64 binary
~/.local/state/ninfer/server.log         server log
~/.local/state/ninfer/server.pid         last background PID
~/.omp/agent/models.yml                  local provider declaration
~/.omp/agent/config.yml                  OMP default role
```

## Idempotence and pinning

The installer is safe to re-run:

- installed Debian packages and CUDA are skipped;
- an existing NInfer checkout and server binary are reused;
- partial model downloads resume with HTTP ranges;
- the model must match both the pinned byte size and SHA-256;
- an existing OMP binary is reused;
- the PATH marker is appended to `.bashrc` once;
- `models.yml` is replaced deterministically;
- `config.yml` is preserved except for the NInfer default role and setup version.

Fresh installs pin the NInfer commit, Hugging Face artifact revision, artifact size and hash, CUDA toolkit line, and OMP version. This prevents an unreviewed upstream or model change from silently producing a different machine.

## Troubleshooting

### `nvidia-smi was not found in WSL`

Install or update the Windows NVIDIA driver, then restart WSL from PowerShell:

```powershell
wsl --shutdown
```

Open Ubuntu again and verify `nvidia-smi`. Do not install a separate Linux NVIDIA display driver inside WSL.

### Service does not become ready

Inspect the log and retry:

```sh
tail -n 100 ~/.local/state/ninfer/server.log
ninfer stop
ninfer serve
```

Common causes are another process using port 8080, insufficient free VRAM, or an incomplete model file. A checksum failure means the artifact must be removed before re-running the installer.

### Port 8080 is already in use

```sh
ss -ltnp | grep ':8080'
```

Stop the conflicting service, then run `ninfer` again.

### Release GPU memory

```sh
ninfer stop
```

The service is intentionally persistent across OMP sessions so reopening OMP does not reload the 20.02 GiB model.

## Source documentation

- [NInfer](https://github.com/Neroued/ninfer)
- [Pinned NInfer revision](https://github.com/Neroued/ninfer/tree/6e8b2e2ad5d53597c3ba8e7989f9546d40b921fc)
- [NInfer CLI guide](https://github.com/Neroued/ninfer/blob/master/docs/cli.md)
- [NInfer serving guide](https://github.com/Neroued/ninfer/blob/master/docs/serving.md)
- [Qwen3.8-27B NVFP4 model card](https://huggingface.co/neroued/Qwen3.8-27B-nvfp4-NInfer)
- [Oh My Pi](https://github.com/can1357/oh-my-pi)
