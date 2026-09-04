#!/usr/bin/env bash
# ============================================================================
# LocalAI in-container installer — runs INSIDE the LXC after creation.
#
# Two deployment paths, chosen automatically:
#   Docker path (default, RECOMMENDED for GPU nodes):
#     - Installs Docker + nvidia-container-toolkit (NVIDIA) / ROCm device
#       access (AMD) / Intel GPU runtime
#     - Runs the official LocalAI container image, which ships ALL backends
#       (diffusers, stablediffusion-cpp, TTS, STT, python backends)
#   Binary path (fallback, or DEPLOY_MODE=binary):
#     - Single GitHub release binary. LIMITED backends: no python backends,
#       no stablediffusion-cpp on Linux. Chat/embeddings only.
#
# Modeled on community-scripts/ProxmoxVE install/*.sh convention.
# ============================================================================
set -e

# --- community-scripts install.func bootstrap (when driven by ct/localai.sh)
if [[ -n "${FUNCTIONS_FILE_PATH:-}" ]]; then
  # shellcheck disable=SC2016
  source /dev/stdin <<<"$FUNCTIONS_FILE_PATH"
  color
  verb_ip6
  catch_errors
  setting_up_container
  network_check
  update_os
else
  # Standalone run inside an existing container:
  msg_info() { echo -e "\e[36m[INFO]\e[0m  $*"; }
  msg_ok()   { echo -e "\e[32m[ OK ]\e[0m  $*"; }
  msg_warn() { echo -e "\e[33m[WARN]\e[0m  $*"; }
  msg_error(){ echo -e "\e[31m[FAIL]\e[0m  $*"; }
  export DEBIAN_FRONTEND=noninteractive
fi

LOCALAI_DIR=/opt/localai
LOCALAI_BIN=/usr/local/bin/local-ai
MODELS_DIR=$LOCALAI_DIR/models
LOCALAI_VERSION="${LOCALAI_VERSION:-latest}"
DEPLOY_MODE="${DEPLOY_MODE:-auto}"   # auto | docker | binary
ARCH=$(uname -m)

msg_info "Installing base dependencies"
if command -v apt >/dev/null 2>&1; then
  apt-get update -qq
  apt-get install -y -qq curl ca-certificates wget jq pciutils gnupg >/dev/null
fi
msg_ok "Base dependencies"

# ----------------------------------------------------------------------------
# GPU detection
# ----------------------------------------------------------------------------
GPU_VENDOR="none"
if lspci 2>/dev/null | grep -qi 'nvidia'; then
  GPU_VENDOR="nvidia"
elif lspci 2>/dev/null | grep -Eiq 'vga.*amd|amd/ati|radeon' && [[ -e /dev/kfd ]]; then
  GPU_VENDOR="amd"
elif lspci 2>/dev/null | grep -Eiq 'intel.*(iris|arc|uhd)' && [[ -e /dev/dri ]]; then
  GPU_VENDOR="intel"
fi
msg_info "GPU vendor detected: ${GPU_VENDOR}"

# ----------------------------------------------------------------------------
# Deployment mode resolution
# ----------------------------------------------------------------------------
if [[ "$DEPLOY_MODE" == "auto" ]]; then
  # Docker for GPU nodes (full backend set incl. diffusers image-gen);
  # binary is fine for CPU-only chat/embeddings nodes.
  if [[ "$GPU_VENDOR" != "none" ]]; then
    DEPLOY_MODE="docker"
  else
    DEPLOY_MODE="binary"
  fi
fi
msg_info "Deployment mode: ${DEPLOY_MODE} (GPU vendor: ${GPU_VENDOR})"

# ----------------------------------------------------------------------------
# Docker + NVIDIA Container Toolkit (docker path)
# ----------------------------------------------------------------------------
install_docker_nvidia() {
  msg_info "Installing Docker + NVIDIA Container Toolkit"
  curl -fsSL https://get.docker.com | sh >/dev/null 2>&1 || { msg_error "Docker install failed"; exit 250; }

  mkdir -p /usr/share/keyrings
  curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
    | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
  curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
    | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
    > /etc/apt/sources.list.d/nvidia-container-toolkit.list
  apt-get update -qq
  apt-get install -y -qq nvidia-container-toolkit >/dev/null
  nvidia-ctk runtime configure --runtime=docker >/dev/null
  systemctl restart docker
  msg_ok "Docker + NVIDIA Container Toolkit installed"

  # Verify GPU visibility from inside a container
  if docker run --rm --gpus all nvidia/cuda:13.1.1-base-ubuntu24.04 nvidia-smi >/dev/null 2>&1; then
    msg_ok "GPU visible inside Docker containers"
  else
    msg_warn "GPU not visible inside Docker containers — check host device mounts"
  fi
}

install_docker_amd() {
  msg_info "Installing Docker (AMD GPU access via /dev/kfd + /dev/dri bind mounts)"
  curl -fsSL https://get.docker.com | sh || { msg_error "Docker install failed"; exit 250; }
  msg_ok "Docker installed (compose adds the device mounts)"
}

install_docker_intel() {
  msg_info "Installing Docker (Intel GPU access via /dev/dri bind mounts)"
  curl -fsSL https://get.docker.com | sh || { msg_error "Docker install failed"; exit 250; }
  msg_ok "Docker installed (compose adds the device mounts)"
}

# ----------------------------------------------------------------------------
# Binary path (CPU-only chat/embeddings; LIMITED backends — see README)
# ----------------------------------------------------------------------------
install_binary() {
  case "$ARCH" in
    x86_64)  LA_OS="Linux";  LA_ARCH="x86_64"  ;;
    aarch64) LA_OS="Linux";  LA_ARCH="arm64"   ;;
    *) msg_error "Unsupported arch: $ARCH"; exit 250 ;;
  esac

  if [[ "$LOCALAI_VERSION" == "latest" ]]; then
    TAG=$(curl -fsSL https://api.github.com/repos/mudler/LocalAI/releases/latest | jq -r '.tag_name')
  else
    TAG="v${LOCALAI_VERSION#v}"
  fi
  [[ -z "$TAG" || "$TAG" == "null" ]] && { msg_error "Could not resolve latest LocalAI release"; exit 250; }

  # v4 asset naming: local-ai-v4.9.0-Linux-x86_64 (single binary, no archive)
  DL_URL="https://github.com/mudler/LocalAI/releases/download/${TAG}/local-ai-${LA_OS}-${LA_ARCH}"
  msg_info "Downloading LocalAI ${TAG} single binary"
  mkdir -p "$LOCALAI_DIR"
  curl -fsSL "$DL_URL" -o "$LOCALAI_BIN" || { msg_error "Download failed: $DL_URL"; exit 250; }
  chmod +x "$LOCALAI_BIN"
  msg_ok "LocalAI binary installed at $LOCALAI_BIN (limited backends: no python/diffusers/stablediffusion-cpp)"
}

# ----------------------------------------------------------------------------
# Docker path: run the official LocalAI AIO image as a systemd service
# ----------------------------------------------------------------------------
install_docker_localai() {
  case "$GPU_VENDOR" in
    nvidia)
      IMAGE="localai/localai:latest-aio-gpu-nvidia-cuda-13"
      GPU_FLAGS="--gpus all"
      ;;
    amd)
      IMAGE="localai/localai:latest-aio-gpu-amd-rocm"
      GPU_FLAGS="--device=/dev/kfd --device=/dev/dri --group-add video --group-add render"
      ;;
    intel)
      IMAGE="localai/localai:latest-gpu-intel"
      GPU_FLAGS="--device=/dev/dri"
      ;;
    *)
      IMAGE="localai/localai:latest"
      GPU_FLAGS=""
      ;;
  esac

  msg_info "Deploying LocalAI container (${IMAGE})"
  mkdir -p "$MODELS_DIR"
  # Pull in the background — it's multi-GB, and the service definition below
  # doesn't depend on the pull finishing to be valid.
  docker pull "$IMAGE" >/dev/null 2>&1 || msg_warn "Initial pull failed — service will retry on start"

  cat > /etc/systemd/system/localai.service <<EOF
[Unit]
Description=LocalAI — OpenAI-compatible API (chat/images/audio)
After=docker.service network-online.target
Requires=docker.service

[Service]
Type=simple
Restart=always
RestartSec=10
ExecStartPre=-/usr/bin/docker rm -f localai
ExecStart=/usr/bin/docker run --name localai --restart no \\
  -p 8080:8080 \\
  ${GPU_FLAGS} \\
  -v ${MODELS_DIR}:/models \\
  -e DEBUG=true \\
  $IMAGE
ExecStop=/usr/bin/docker stop localai

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable -q --now localai
  msg_ok "localai.service enabled (docker: ${IMAGE})"
}

# Persist the deployment mode — the updater reads it to know which path to run.
write_deploy_mode() {
  echo "$DEPLOY_MODE" > "$LOCALAI_DIR/deploy-mode"
  msg_ok "Deployment mode persisted: ${DEPLOY_MODE}"
}

# ----------------------------------------------------------------------------
# Binary path: model configs + native systemd service
# ----------------------------------------------------------------------------
install_binary_localai() {
  msg_info "Writing model configs to $MODELS_DIR"
  mkdir -p "$MODELS_DIR"

  # Small chat LLM (works on CPU or any GPU) — Qwen2.5 3B Instruct q4
  cat > "$MODELS_DIR/qwen2.5-3b-chat.yaml" <<'EOF'
name: qwen2.5-3b-chat
backend: llama-cpp
parameters:
  model: huggingface://Qwen/Qwen2.5-3B-Instruct-GGUF/qwen2.5-3b-instruct-q4_k_m.gguf
context_size: 8192
gpu_layers: 99
f16: true
EOF

  # Embeddings — tiny
  cat > "$MODELS_DIR/embeddings.yaml" <<'EOF'
embeddings: true
name: text-embedding-ada-002
backend: llama-cpp
parameters:
  model: huggingface://bartowski/granite-embedding-107m-multilingual-GGUF/granite-embedding-107m-multilingual-f16.gguf
EOF

  if [[ "$GPU_VENDOR" == "none" ]]; then
    msg_warn "CPU-only binary mode: image generation is NOT available (diffusers backend needs Docker). Chat + embeddings only."
  fi

  cat > /etc/systemd/system/localai.service <<EOF
[Unit]
Description=LocalAI — OpenAI-compatible API (chat/embeddings)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=$LOCALAI_DIR
ExecStart=$LOCALAI_BIN run --models-path $MODELS_DIR --host 0.0.0.0 --port 8080
Environment=MODELS_PATH=$MODELS_DIR
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable -q --now localai
  msg_ok "localai.service enabled (binary mode)"
}

# ----------------------------------------------------------------------------
# Execute the chosen path
# ----------------------------------------------------------------------------
msg_info "Deployment mode: ${DEPLOY_MODE}"
case "$DEPLOY_MODE" in
  docker)
    case "$GPU_VENDOR" in
      nvidia) install_docker_nvidia ;;
      amd)    install_docker_amd ;;
      intel)  install_docker_intel ;;
      *)      curl -fsSL https://get.docker.com | sh >/dev/null 2>&1 || true ;;
    esac
    install_docker_localai
    ;;
  binary)
    install_binary
    install_binary_localai
    ;;
  *)
    msg_error "Unknown DEPLOY_MODE: $DEPLOY_MODE (use auto|docker|binary)"
    exit 250
    ;;
esac

# Persist deployment mode + ship the in-container updater
write_deploy_mode

# ----------------------------------------------------------------------------
# Verification
# ----------------------------------------------------------------------------
sleep 8
if systemctl is-active --quiet localai; then
  msg_ok "LocalAI is running"
else
  msg_error "LocalAI failed to start — check 'journalctl -u localai' (docker path: 'docker logs localai')"
fi

if [[ "$DEPLOY_MODE" == "docker" ]]; then
  case "$GPU_VENDOR" in
    nvidia)
      if docker exec localai nvidia-smi >/dev/null 2>&1; then
        msg_ok "GPU visible inside the LocalAI container — CUDA inference available"
      else
        msg_warn "GPU not visible inside the container — check host device mounts (LocalAI falls back to CPU)"
      fi
      ;;
    amd)
      [[ -e /dev/kfd ]] && msg_ok "/dev/kfd visible — ROCm should initialize" \
        || msg_warn "/dev/kfd missing — check host device mounts"
      ;;
  esac
else
  msg_ok "Binary mode — CPU-only verification skipped"
fi

# ----------------------------------------------------------------------------
# community-scripts housekeeping (when driven via ct/localai.sh)
# ----------------------------------------------------------------------------
if declare -F motd_ssh >/dev/null 2>&1; then
  motd_ssh
  customize
  cleanup_lxc
fi

IP=$(hostname -I | awk '{print $1}')
msg_ok "LocalAI installation complete — API: http://${IP}:8080/v1 (${DEPLOY_MODE}/${GPU_VENDOR})"
