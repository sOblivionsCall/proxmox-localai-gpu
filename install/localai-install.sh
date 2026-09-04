#!/usr/bin/env bash
# ============================================================================
# LocalAI in-container installer — runs INSIDE the LXC after creation.
#
# Single deployment path: the official LocalAI release BINARY (works for CPU
# and GPU alike). The user is responsible for the platform underneath:
#   - GPU: host driver + device passthrough (handled by the ct script via
#     the community-scripts engine, var_gpu=yes). Inside the container we
#     only check that the device nodes are visible and report honestly.
#   - CPU: nothing extra needed.
#
# Known limitation of the binary (documented by upstream): no Python-based
# backends (diffusers, transformers) and no stablediffusion-cpp — so image
# generation via those backends is not available in binary mode. Chat
# (llama-cpp), embeddings, and reranking work fully, with GPU offload when
# the device is visible.
#
# If image generation is required, run LocalAI via Docker instead:
#   docker run -p 8080:8080 --gpus all -v ./models:/models localai/localai:latest-aio-gpu-nvidia-cuda-13
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

msg_info "Installing base dependencies"
if command -v apt >/dev/null 2>&1; then
  apt-get update -qq
  apt-get install -y -qq curl ca-certificates wget jq pciutils >/dev/null
fi
msg_ok "Base dependencies"

# ----------------------------------------------------------------------------
# GPU detection — report what we see. The platform (host driver + device
# mounts) is the user's responsibility; we only verify and report honestly.
# ----------------------------------------------------------------------------
GPU_STATUS="cpu"
if lspci 2>/dev/null | grep -qi 'nvidia' && command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi >/dev/null 2>&1; then
  GPU_STATUS="nvidia"
elif [[ -e /dev/kfd ]]; then
  GPU_STATUS="amd"
elif [[ -e /dev/dri ]] && lspci 2>/dev/null | grep -Eiq 'intel.*(iris|arc|uhd)'; then
  GPU_STATUS="intel"
fi
msg_info "GPU status: ${GPU_STATUS}"
case "$GPU_STATUS" in
  nvidia) msg_ok "NVIDIA device visible — llama.cpp will offload layers (gpu_layers: 99 in model configs)" ;;
  amd)    msg_ok "AMD /dev/kfd visible — ROCm-capable builds can use it" ;;
  intel)  msg_ok "Intel GPU visible — Level-Zero-capable builds can use it" ;;
  *)      msg_warn "No GPU visible — LocalAI will run CPU-only" ;;
esac

# ----------------------------------------------------------------------------
# LocalAI binary — v4 single-binary release asset naming
# ----------------------------------------------------------------------------
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

DL_URL="https://github.com/mudler/LocalAI/releases/download/${TAG}/local-ai-${LA_OS}-${LA_ARCH}"
msg_info "Downloading LocalAI ${TAG} binary"
mkdir -p "$LOCALAI_DIR"
curl -fsSL "$DL_URL" -o "$LOCALAI_BIN" || { msg_error "Download failed: $DL_URL"; exit 250; }
chmod +x "$LOCALAI_BIN"
msg_ok "LocalAI binary installed at $LOCALAI_BIN"

# ----------------------------------------------------------------------------
# Model configs — chat LLM, embeddings. gpu_layers: 99 = "offload what fits",
# so the same configs serve CPU-only and GPU-visible containers.
# ----------------------------------------------------------------------------
msg_info "Writing model configs to $MODELS_DIR"
mkdir -p "$MODELS_DIR"

cat > "$MODELS_DIR/qwen2.5-3b-chat.yaml" <<'EOF'
name: qwen2.5-3b-chat
backend: llama-cpp
parameters:
  model: huggingface://Qwen/Qwen2.5-3B-Instruct-GGUF/qwen2.5-3b-instruct-q4_k_m.gguf
context_size: 8192
gpu_layers: 99
f16: true
EOF

cat > "$MODELS_DIR/embeddings.yaml" <<'EOF'
embeddings: true
name: text-embedding-ada-002
backend: llama-cpp
parameters:
  model: huggingface://bartowski/granite-embedding-107m-multilingual-GGUF/granite-embedding-107m-multilingual-f16.gguf
EOF

msg_ok "Model configs written (models download on first use)"

if [[ "$GPU_STATUS" == "cpu" ]]; then
  msg_warn "CPU-only: chat + embeddings will work. Image generation is NOT available in binary mode (needs the Docker image with diffusers)."
fi

# ----------------------------------------------------------------------------
# systemd service
# ----------------------------------------------------------------------------
msg_info "Creating systemd service"
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
msg_ok "localai.service enabled"

# Persist deployment mode for the updater
echo "binary" > "$LOCALAI_DIR/deploy-mode"
msg_ok "Deployment mode persisted: binary"

# ----------------------------------------------------------------------------
# Verification
# ----------------------------------------------------------------------------
sleep 8
if systemctl is-active --quiet localai; then
  msg_ok "LocalAI is running"
else
  msg_error "LocalAI failed to start — check 'journalctl -u localai'"
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
msg_ok "LocalAI installation complete — API: http://${IP}:8080/v1 (binary, ${GPU_STATUS})"
