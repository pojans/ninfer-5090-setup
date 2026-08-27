#!/bin/sh
# NInfer-5090 + Oh My Pi installer for WSL2 Ubuntu.
#
# Install:
#   curl -fsSL https://raw.githubusercontent.com/pojans/ninfer-5090-setup/main/install.sh | sh
#
# Re-running this installer is safe. Use --no-launch to provision without
# starting the service or opening the OMP TUI.

set -eu

NINFER_REPO_URL="https://github.com/Neroued/ninfer.git"
NINFER_BRANCH="master"
NINFER_REV="6e8b2e2ad5d53597c3ba8e7989f9546d40b921fc"
REPO_DIR="$HOME/projects/ninfer-5090"
SERVER="$REPO_DIR/build/apps/ninfer-serve"
MODEL="$REPO_DIR/models/qwen3_8_27b_nvfp4.ninfer"
MODEL_SIZE="21492695040"
MODEL_SHA256="bb3360522a06e136e0367f5703414d26272b7285c8a6ab6194135c17dbd81b32"
MODEL_URL="https://huggingface.co/neroued/Qwen3.8-27B-nvfp4-NInfer/resolve/3b84117e0fd258b45bd79778ec8d8f27a4ab3d56/qwen3_8_27b_nvfp4.ninfer"
CUDA_DIR="/usr/local/cuda-13.1"
OMP_VERSION="v18.0.4"
BIN_DIR="$HOME/.local/bin"
NINFER_BIN="$BIN_DIR/ninfer"
NO_LAUNCH=0

usage() {
    cat <<'EOF'
Usage: install.sh [--no-launch]

Installs NInfer-5090, its Qwen3.8-27B NVFP4 model, CUDA 13.1, and Oh My Pi in WSL2.
By default the installer starts NInfer and opens the OMP TUI when finished.
EOF
}

log() {
    printf '\n==> %s\n' "$*"
}

die() {
    printf '\nERROR: %s\n' "$*" >&2
    exit 1
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --no-launch)
            NO_LAUNCH=1
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            die "Unknown option: $1"
            ;;
    esac
    shift
done

if [ "$(id -u)" -eq 0 ]; then
    SUDO=""
else
    command -v sudo >/dev/null 2>&1 || die "sudo is required for system packages."
    SUDO="sudo"
fi

run_root() {
    if [ -n "$SUDO" ]; then
        sudo "$@"
    else
        "$@"
    fi
}

log "Checking WSL, GPU, and disk space"
if [ ! -r /proc/sys/kernel/osrelease ] || ! grep -qi microsoft /proc/sys/kernel/osrelease; then
    die "This installer must run inside WSL2 Ubuntu, not Windows or native Linux."
fi
command -v apt-get >/dev/null 2>&1 || die "apt-get was not found. Install an Ubuntu WSL2 distribution first."
command -v nvidia-smi >/dev/null 2>&1 || die "nvidia-smi was not found in WSL. Install the current Windows NVIDIA driver, run 'wsl --shutdown', and try again."
if ! GPU_NAME=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | sed -n '1p'); then
    die "The NVIDIA GPU is not visible in WSL. Update the Windows NVIDIA driver and restart WSL."
fi
case "$GPU_NAME" in
    *"RTX 5090"*) ;;
    *) die "This profile requires an RTX 5090; WSL reported: $GPU_NAME" ;;
esac
printf '    GPU: %s\n' "$GPU_NAME"

AVAILABLE_KB=$(df -Pk "$HOME" | awk 'NR == 2 { print $4 }')
case "$AVAILABLE_KB" in
    ''|*[!0-9]*) die "Could not determine free disk space under $HOME." ;;
esac
AVAILABLE_GB=$((AVAILABLE_KB / 1024 / 1024))
REQUIRED_GB=5
CURRENT_MODEL_SIZE=0
if [ -f "$MODEL" ]; then
    CURRENT_MODEL_SIZE=$(wc -c < "$MODEL" | tr -d ' ')
fi
if [ "$CURRENT_MODEL_SIZE" -ne "$MODEL_SIZE" ]; then
    REQUIRED_GB=30
elif [ ! -x "$SERVER" ] || [ ! -x "$CUDA_DIR/bin/nvcc" ]; then
    REQUIRED_GB=15
fi
if [ "$AVAILABLE_GB" -lt "$REQUIRED_GB" ]; then
    die "At least ${REQUIRED_GB} GB must be free under $HOME; only ${AVAILABLE_GB} GB is available."
fi
printf '    Free disk: %s GB\n' "$AVAILABLE_GB"

log "Installing build dependencies"
MISSING_PACKAGES=""
for PACKAGE in build-essential cmake ninja-build git curl ca-certificates procps pkg-config \
    libavformat-dev libavcodec-dev libavutil-dev libswscale-dev libcurl4-openssl-dev; do
    if ! dpkg-query -W -f='${Status}' "$PACKAGE" 2>/dev/null | grep -q 'ok installed'; then
        MISSING_PACKAGES="$MISSING_PACKAGES $PACKAGE"
    fi
done
if [ -n "$MISSING_PACKAGES" ]; then
    run_root apt-get update
    # Package names above are fixed, so intentional word splitting is safe.
    # shellcheck disable=SC2086
    run_root env DEBIAN_FRONTEND=noninteractive apt-get install -y $MISSING_PACKAGES
else
    printf '    Dependencies already installed.\n'
fi

log "Ensuring CUDA 13.1 is installed"
if [ ! -x "$CUDA_DIR/bin/nvcc" ]; then
    CUDA_KEYRING=$(mktemp)
    curl -fL --retry 3 -o "$CUDA_KEYRING" \
        "https://developer.download.nvidia.com/compute/cuda/repos/wsl-ubuntu/x86_64/cuda-keyring_1.1-1_all.deb"
    run_root dpkg -i "$CUDA_KEYRING"
    rm -f "$CUDA_KEYRING"
    run_root apt-get update
    run_root env DEBIAN_FRONTEND=noninteractive apt-get install -y cuda-toolkit-13-1
else
    printf '    CUDA 13.1 already installed.\n'
fi
export CUDA_HOME="$CUDA_DIR"
export PATH="$CUDA_DIR/bin:$BIN_DIR:$HOME/.bun/bin:$PATH"
"$CUDA_DIR/bin/nvcc" --version >/dev/null 2>&1 || die "CUDA 13.1 was installed but nvcc cannot start."

log "Ensuring NInfer source is available"
if git -C "$REPO_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    printf '    Using existing checkout: %s\n' "$REPO_DIR"
else
    if [ -e "$REPO_DIR" ]; then
        [ -d "$REPO_DIR" ] || die "$REPO_DIR exists and is not a directory."
        [ -z "$(ls -A "$REPO_DIR")" ] || die "$REPO_DIR exists but is not a Git checkout. Move it aside and re-run this installer."
    else
        mkdir -p "$(dirname "$REPO_DIR")"
    fi
    git clone --depth 1 --branch "$NINFER_BRANCH" "$NINFER_REPO_URL" "$REPO_DIR"
    if ! git -C "$REPO_DIR" cat-file -e "$NINFER_REV^{commit}" 2>/dev/null; then
        git -C "$REPO_DIR" fetch --depth 1 origin "$NINFER_REV"
    fi
    git -C "$REPO_DIR" checkout --detach "$NINFER_REV"
fi

log "Ensuring NInfer server is built"
if [ ! -x "$SERVER" ]; then
    printf '    Building Release binary; this can take 15-30 minutes.\n'
    if [ -f "$REPO_DIR/build/CMakeCache.txt" ]; then
        cmake -S "$REPO_DIR" -B "$REPO_DIR/build" -DCMAKE_BUILD_TYPE=Release
    else
        cmake -S "$REPO_DIR" -B "$REPO_DIR/build" -G Ninja -DCMAKE_BUILD_TYPE=Release
    fi
    cmake --build "$REPO_DIR/build" --parallel "$(nproc)"
else
    printf '    Server binary already built.\n'
fi
[ -x "$SERVER" ] || die "NInfer build completed without producing $SERVER."

log "Ensuring Qwen3.8-27B NVFP4 model is downloaded"
mkdir -p "$(dirname "$MODEL")"
CURRENT_MODEL_SIZE=0
if [ -f "$MODEL" ]; then
    CURRENT_MODEL_SIZE=$(wc -c < "$MODEL" | tr -d ' ')
fi
if [ "$CURRENT_MODEL_SIZE" -gt "$MODEL_SIZE" ]; then
    die "$MODEL is larger than the verified model. Move it aside and re-run this installer."
fi
if [ "$CURRENT_MODEL_SIZE" -lt "$MODEL_SIZE" ]; then
    printf '    Downloading 20.02 GiB; interrupted downloads resume on the next run.\n'
    curl -fL -C - --retry 5 --retry-delay 5 -o "$MODEL" "$MODEL_URL"
fi
CURRENT_MODEL_SIZE=$(wc -c < "$MODEL" | tr -d ' ')
[ "$CURRENT_MODEL_SIZE" -eq "$MODEL_SIZE" ] || die "Model download is incomplete: expected $MODEL_SIZE bytes, found $CURRENT_MODEL_SIZE. Re-run the installer to resume."
if ! printf '%s  %s\n' "$MODEL_SHA256" "$MODEL" | sha256sum --check --status 2>/dev/null; then
    die "Model SHA-256 verification failed for $MODEL; remove the file and re-run the installer."
fi
printf '    Model ready: %s\n' "$MODEL"

log "Installing the ninfer command"
mkdir -p "$BIN_DIR"
cat > "$NINFER_BIN" <<'NINFER_COMMAND'
#!/bin/sh
# Start the local NInfer service if necessary, then launch Oh My Pi.
set -eu

export PATH="/usr/local/cuda-13.1/bin:$HOME/.local/bin:$HOME/.bun/bin:$PATH"
export CUDA_HOME="/usr/local/cuda-13.1"

REPO_DIR="$HOME/projects/ninfer-5090"
SERVER="$REPO_DIR/build/apps/ninfer-serve"
MODEL="$REPO_DIR/models/qwen3_8_27b_nvfp4.ninfer"
STATE_DIR="$HOME/.local/state/ninfer"
LOG_FILE="$STATE_DIR/server.log"
PID_FILE="$STATE_DIR/server.pid"
HEALTH_URL="http://127.0.0.1:8080/v1/models"

usage() {
    cat <<'EOF'
Usage: ninfer [serve|status|stop]

  ninfer         Start NInfer if needed, then open the OMP TUI.
  ninfer serve   Start NInfer if needed without opening OMP.
  ninfer status  Show service and GPU status.
  ninfer stop    Stop the NInfer service and release GPU memory.
EOF
}

die() {
    printf 'ninfer: %s\n' "$*" >&2
    exit 1
}

healthy() {
    curl -fsS --connect-timeout 2 "$HEALTH_URL" >/dev/null 2>&1
}

server_process_exists() {
    pgrep -f -- "$SERVER" >/dev/null 2>&1
}

show_log_tail() {
    if [ -f "$LOG_FILE" ]; then
        printf '\nLast server log lines:\n' >&2
        tail -n 30 "$LOG_FILE" >&2
    fi
}

wait_until_ready() {
    ATTEMPT=0
    while [ "$ATTEMPT" -lt 120 ]; do
        if healthy; then
            return 0
        fi
        if [ "$ATTEMPT" -gt 0 ] && ! server_process_exists; then
            return 1
        fi
        ATTEMPT=$((ATTEMPT + 1))
        sleep 5
    done
    return 1
}

ensure_service() {
    if healthy; then
        printf 'NInfer service is ready at %s\n' "$HEALTH_URL"
        return 0
    fi

    if server_process_exists; then
        printf 'NInfer is loading; waiting for it to become ready...\n'
    else
        [ -x "$SERVER" ] || die "server binary is missing; re-run the installer"
        [ -s "$MODEL" ] || die "model is missing; re-run the installer"
        mkdir -p "$STATE_DIR"
        printf 'Starting NInfer; loading the model normally takes 1-3 minutes...\n'
        nohup "$SERVER" "$MODEL" \
            --host 127.0.0.1 \
            --port 8080 \
            --max-context 131072 \
            --kv-capacity 131072 \
            --max-concurrency 2 \
            --max-pending-requests 16 \
            --pending-timeout-ms 600000 \
            --prefill-chunk 1024 \
            --kv-dtype int8 \
            --spec mtp \
            --draft-tokens 3 \
            --lm-head-draft \
            --preserve-thinking \
            </dev/null >>"$LOG_FILE" 2>&1 &
        printf '%s\n' "$!" > "$PID_FILE"
    fi

    if ! wait_until_ready; then
        rm -f "$PID_FILE"
        show_log_tail
        die "service did not become ready within 10 minutes"
    fi
    printf 'NInfer service is ready at %s\n' "$HEALTH_URL"
}

stop_service() {
    if ! server_process_exists; then
        rm -f "$PID_FILE"
        printf 'NInfer service is not running.\n'
        return 0
    fi
    pkill -TERM -f -- "$SERVER" 2>/dev/null || true
    ATTEMPT=0
    while server_process_exists && [ "$ATTEMPT" -lt 30 ]; do
        ATTEMPT=$((ATTEMPT + 1))
        sleep 1
    done
    if server_process_exists; then
        pkill -KILL -f -- "$SERVER" 2>/dev/null || true
    fi
    rm -f "$PID_FILE"
    printf 'NInfer service stopped.\n'
}

COMMAND="${1:-}"
case "$COMMAND" in
    "")
        ensure_service
        if [ -x "$HOME/.local/bin/omp" ]; then
            OMP="$HOME/.local/bin/omp"
        elif command -v omp >/dev/null 2>&1; then
            OMP=$(command -v omp)
        else
            die "omp is not installed; re-run the installer"
        fi
        if [ -t 1 ] && [ -r /dev/tty ]; then
            exec "$OMP" </dev/tty
        fi
        printf 'Run ninfer from an interactive WSL terminal to open OMP.\n'
        ;;
    serve)
        ensure_service
        ;;
    status)
        if healthy; then
            printf 'Service: ready (%s)\n' "$HEALTH_URL"
            STATUS=0
        elif server_process_exists; then
            printf 'Service: process running but endpoint not ready\n'
            STATUS=1
        else
            printf 'Service: stopped\n'
            STATUS=1
        fi
        nvidia-smi --query-gpu=name,memory.used,memory.total --format=csv,noheader 2>/dev/null || true
        exit "$STATUS"
        ;;
    stop)
        stop_service
        ;;
    -h|--help|help)
        usage
        ;;
    *)
        usage >&2
        exit 1
        ;;
esac
NINFER_COMMAND
chmod 755 "$NINFER_BIN"

BASHRC="$HOME/.bashrc"
if ! grep -Fq '# ninfer-5090-setup PATH' "$BASHRC" 2>/dev/null; then
    cat >> "$BASHRC" <<'EOF'

# ninfer-5090-setup PATH
export PATH="$HOME/.local/bin:$PATH"
EOF
fi
printf '    Installed: %s\n' "$NINFER_BIN"

log "Installing Oh My Pi in WSL"
if [ ! -x "$BIN_DIR/omp" ]; then
    curl -fsSL https://omp.sh/install | sh -s -- --binary --ref "$OMP_VERSION"
else
    printf '    OMP binary already installed.\n'
fi
[ -x "$BIN_DIR/omp" ] || die "OMP installation did not produce $BIN_DIR/omp."
"$BIN_DIR/omp" --version >/dev/null 2>&1 || die "OMP is installed but cannot start."

log "Configuring OMP to use NInfer by default"
OMP_DIR="$HOME/.omp/agent"
MODELS_FILE="$OMP_DIR/models.yml"
CONFIG_FILE="$OMP_DIR/config.yml"
mkdir -p "$OMP_DIR"

MODELS_TMP="$MODELS_FILE.tmp.$$"
cat > "$MODELS_TMP" <<'EOF'
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
        contextWindow: 131072
        maxTokens: 8192
EOF
if [ -f "$MODELS_FILE" ] && cmp -s "$MODELS_TMP" "$MODELS_FILE"; then
    rm -f "$MODELS_TMP"
else
    mv "$MODELS_TMP" "$MODELS_FILE"
fi

if [ ! -f "$CONFIG_FILE" ]; then
    cat > "$CONFIG_FILE" <<'EOF'
modelRoles:
  default: llama.cpp/qwen3.8-27b:xhigh
setupVersion: 3
EOF
else
    CONFIG_TMP="$CONFIG_FILE.tmp.$$"
    awk -v role='llama.cpp/qwen3.8-27b:xhigh' '
        BEGIN { in_roles = 0; found_roles = 0; wrote_default = 0 }
        /^modelRoles:[[:space:]]*$/ {
            in_roles = 1
            found_roles = 1
            print
            next
        }
        in_roles && /^[^[:space:]#]/ {
            if (!wrote_default) {
                print "  default: " role
                wrote_default = 1
            }
            in_roles = 0
        }
        in_roles && /^  default:[[:space:]]*/ {
            print "  default: " role
            wrote_default = 1
            next
        }
        { print }
        END {
            if (found_roles && in_roles && !wrote_default) {
                print "  default: " role
            }
            if (!found_roles) {
                print ""
                print "modelRoles:"
                print "  default: " role
            }
        }
    ' "$CONFIG_FILE" > "$CONFIG_TMP"
    mv "$CONFIG_TMP" "$CONFIG_FILE"

    if grep -q '^setupVersion:' "$CONFIG_FILE"; then
        CONFIG_TMP="$CONFIG_FILE.tmp.$$"
        awk '/^setupVersion:/ { print "setupVersion: 3"; next } { print }' "$CONFIG_FILE" > "$CONFIG_TMP"
        mv "$CONFIG_TMP" "$CONFIG_FILE"
    else
        printf '\nsetupVersion: 3\n' >> "$CONFIG_FILE"
    fi
fi

printf '\nInstallation complete. Daily command: ninfer\n'
printf '  ninfer         start the service and open OMP\n'
printf '  ninfer status  check service and GPU state\n'
printf '  ninfer stop    stop the service and release VRAM\n'

if [ "$NO_LAUNCH" -eq 1 ]; then
    printf '\nLaunch later with: ninfer\n'
    exit 0
fi

if [ -t 1 ] && [ -r /dev/tty ]; then
    exec "$NINFER_BIN"
fi

"$NINFER_BIN" serve
