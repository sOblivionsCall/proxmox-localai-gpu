#!/usr/bin/env bash
# ============================================================================
# LocalAI in-container installer — runs INSIDE the LXC after creation.
#
# Supports three hardware profiles, auto-detected:
#   nvidia — CUDA userspace + nvidia-container-toolkit (GPU inference)
#   amd    — ROCm userspace (GPU inference)
#   intel  — Level Zero userspace (GPU inference)
#   none   — CPU-only (no GPU, or GPU passthrough not configured)
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
ARCH=$(uname -m)

msg_info "Installing base dependencies"
if command -v apt >/dev/null 2>&1; then
  apt-get update -qq
  apt-get install -y -qq curl ca-certificates wget jq pciutils >/dev/null
fi
msg_ok "Base dependencies"

# ----------------------------------------------------------------------------
# GPU detection + userspace runtime install
# ----------------------------------------------------------------------------
GPU_VENDOR="none"
if lspci 2>/dev/null | grep -qi 'nvidia'; then
  GPU_VENDOR="nvidia"
elif lspci 2>/dev/null | grep -Eiq 'vga.*amd|amd/ati|radeon'; then
  if [[ -e /dev/kfd ]]; then
    GPU_VENDOR="amd"
  fi
elif lspci 2>/dev/null | grep -Eiq 'intel.*(iris|arc|uhd)'; then
  GPU_VENDOR="intel"
fi

msg_info "GPU vendor detected: ${GPU_VENDOR}"

install_nvidia_userspace() {
  # Userspace only. Kernel driver lives on the Proxmox host.
  msg_info "Installing NVIDIA userspace + Container Toolkit"
  apt-get install -y -qq gnupg >/dev/null
  mkdir -p /usr/share/keyrings
  curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
    | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
  curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
    | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
    > /etc/apt/sources.list.d/nvidia-container-toolkit.list
  apt-get update -qq
  apt-get install -y -qq libnvidia-container-tools nvidia-container-toolkit >/dev/null
  # CUDA runtime libs for the native LocalAI binary (Docker users get them
  # injected via the toolkit instead).
  apt-get install -y -qq libcublas-13-1 libcudart-13-1 2>/dev/null \
    || msg_warn "CUDA runtime libs not found in repo — install manually if GPU inference fails"
  msg_ok "NVIDIA userspace installed"
}

install_amd_userspace() {
  msg_info "Installing AMD ROCm userspace (this is large, patience)"
  mkdir -p /usr/share/keyrings
  curl -fsSL https://repo.radeon.com/rocm/rocm.gpg.key \
    | gpg --dearmor -o /usr/share/keyrings/rocm-keyring.gpg
  echo "deb [signed-by=/usr/share/keyrings/rocm-keyring.gpg] https://repo.radeon.com/rocm/apt/6.2 jammy main" \
    > /etc/apt/sources.list.d/rocm.list
  apt-get update -qq
  apt-get install -y -qq rocm-hip-libraries >/dev/null || msg_warn "ROCm install incomplete"
  msg_ok "AMD ROCm userspace installed"
}

install_intel_userspace() {
  msg_info "Installing Intel Level Zero userspace"
  mkdir -p /usr/share/keyrings
  curl -fsSL https://repositories.intel.com/gpu/intel-graphics.key \
    | gpg --dearmor -o /usr/share/keyrings/intel-graphics.gpg
  echo "deb [signed-by=/usr/share/keyrings/intel-graphics.gpg] https://repositories.intel.com/gpu/ubuntu jammy client" \
    > /etc/apt/sources.list.d/intel-gpu.sources
  apt-get update -qq
  apt-get install -y -qq intel-level-zero-gpu level-zero level-zero-dev >/dev/null 2>&1 || msg_warn "Level Zero install incomplete"
  msg_ok "Intel Level Zero installed"
}

case "$GPU_VENDOR" in
  nvidia) install_nvidia_userspace ;;
  amd)    install_amd_userspace ;;
  intel)  install_intel_userspace ;;
  *)      msg_ok "No GPU detected — installing CPU-only LocalAI (works fine, slower for large models)" ;;
esac

# ----------------------------------------------------------------------------
# LocalAI binary
# ----------------------------------------------------------------------------
msg_info "Downloading LocalAI (${LOCALAI_VERSION}, ${ARCH})"
mkdir -p "$LOCALAI_DIR" "$MODELS_DIR"
case "$ARCH" in
  x86_64) LA_ARCH="x86_64" ;;
  aarch64|arm64) LA_ARCH="arm64" ;;
  *) msg_error "Unsupported arch: $ARCH"; exit 250 ;;
esac

if [[ "$LOCALAI_VERSION" == "latest" ]]; then
  DL_URL=$(curl -fsSL https://api.github.com/repos/mudler/LocalAI/releases/latest \
    | jq -r ".assets[] | select(.name | contains(\"linux-${LA_ARCH}\")) | select(.name | endswith(\".tar.gz\")) | .browser_download_url" | head -1)
else
  DL_URL=$(curl -fsSL "https://api.github.com/repos/mudler/LocalAI/releases/tags/v${LOCALAI_VERSION#v}" \
    | jq -r ".assets[] | select(.name | contains(\"linux-${LA_ARCH}\")) | select(.name | endswith(\".tar.gz\")) | .browser_download_url" | head -1)
fi
if [[ -z "$DL_URL" || "$DL_URL" == "null" ]]; then
  msg_error "Could not resolve a LocalAI release asset for linux-${LA_ARCH}"
  exit 250
fi
curl -fsSL "$DL_URL" -o /tmp/localai.tar.gz
tar -xzf /tmp/localai.tar.gz -C "$LOCALAI_DIR"
if [[ -f "$LOCALAI_DIR/local-ai" ]]; then
  ln -sf "$LOCALAI_DIR/local-ai" "$LOCALAI_BIN"
elif [[ -f "$LOCALAI_DIR/usr/local/bin/local-ai" ]]; then
  ln -sf "$LOCALAI_DIR/usr/local/bin/local-ai" "$LOCALAI_BIN"
else
  FOUND=$(find "$LOCALAI_DIR" -maxdepth 3 -name 'local-ai' -type f | head -1)
  [[ -n "$FOUND" ]] && ln -sf "$FOUND" "$LOCALAI_BIN" || { msg_error "local-ai binary not found after unpack"; exit 250; }
fi
chmod +x "$LOCALAI_BIN"
rm -f /tmp/localai.tar.gz
msg_ok "LocalAI installed at $LOCALAI_BIN"

# ----------------------------------------------------------------------------
# Model configs — chat LLM (small), image gen, embeddings
# ----------------------------------------------------------------------------
msg_info "Writing model configs to $MODELS_DIR"

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

# Image generation — SD1.5-class via stablediffusion-ggml (smallest footprint)
cat > "$MODELS_DIR/stablediffusion.yaml" <<'EOF'
name: stablediffusion
backend: stablediffusion-ggml
parameters:
  model: huggingface://second-state/stable-diffusion-v1-5-GGUF/stable-diffusion-v1-5-pruned-emaonly-Q4_0.gguf
step: 25
cfg_scale: 4.5
EOF

# Embeddings — tiny
cat > "$MODELS_DIR/embeddings.yaml" <<'EOF'
embeddings: true
name: text-embedding-ada-002
backend: llama-cpp
parameters:
  model: huggingface://bartowski/granite-embedding-107m-multilingual-GGUF/granite-embedding-107m-multilingual-f16.gguf
EOF

msg_ok "Model configs written (models download on first use)"

# ----------------------------------------------------------------------------
# systemd service
# ----------------------------------------------------------------------------
msg_info "Creating systemd service"
cat > /etc/systemd/system/localai.service <<EOF
[Unit]
Description=LocalAI — OpenAI-compatible API (chat/images/audio)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=$LOCALAI_DIR
ExecStart=$LOCALAI_BIN run --models-path $MODELS_DIR --host 0.0.0.0 --port 8080 --context-size 2048
Environment=MODELS_PATH=$MODELS_DIR
Environment=GALLERIES=[{"name":"model-gallery","url":"github:mudler/LocalAI/gallery/index.yaml@master"}]
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

# GPU-specific env additions
if [[ "$GPU_VENDOR" == "nvidia" ]]; then
  sed -i "/\[Service\]/a Environment=LD_LIBRARY_PATH=/usr/lib/x86_64-linux-gnu:/usr/local/cuda/lib64" \
    /etc/systemd/system/localai.service
elif [[ "$GPU_VENDOR" == "amd" ]]; then
  sed -i "/\[Service\]/a Environment=LD_LIBRARY_PATH=/opt/rocm/lib" \
    /etc/systemd/system/localai.service
fi
# CPU-only containers need no GPU env.

systemctl daemon-reload
systemctl enable -q --now localai
msg_ok "localai.service enabled"

# ----------------------------------------------------------------------------
# Verification
# ----------------------------------------------------------------------------
sleep 5
if systemctl is-active --quiet localai; then
  msg_ok "LocalAI is running"
else
  msg_error "LocalAI failed to start — check 'journalctl -u localai'"
fi

case "$GPU_VENDOR" in
  nvidia)
    if nvidia-smi >/dev/null 2>&1; then
      msg_ok "nvidia-smi works inside the container — GPU visible"
    else
      msg_warn "nvidia-smi not functional — check host driver + device mounts (falling back to CPU)"
    fi
    ;;
  amd)
    if [[ -e /dev/kfd ]]; then
      msg_ok "/dev/kfd visible — ROCm should initialize"
    else
      msg_warn "/dev/kfd missing — check host device mounts (falling back to CPU)"
    fi
    ;;
  *)
    msg_ok "CPU-only mode — no GPU verification needed"
    ;;
esac

# ----------------------------------------------------------------------------
# community-scripts housekeeping (when driven via ct/localai.sh)
# ----------------------------------------------------------------------------
if declare -F motd_ssh >/dev/null 2>&1; then
  motd_ssh
  customize
  cleanup_lxc
fi

IP=$(hostname -I | awk '{print $1}')
msg_ok "LocalAI installation complete — API: http://${IP}:8080/v1 (${GPU_VENDOR} mode)"
