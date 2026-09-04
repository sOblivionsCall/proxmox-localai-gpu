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
# BACKENDS: since LocalAI v3.2 all backends live OUTSIDE the binary as OCI
# images. LocalAI pulls and runs them itself — daemonless, no Docker needed.
# Backends auto-install on first use of a model that needs them, or can be
# pre-installed:  local-ai backends install <name>
# e.g. diffusers (image gen), piper (TTS), whisper (STT) all work in binary
# mode. The only true limitation: the binary ships no CORE backends, so the
# first model load pulls its backend over the network (needs connectivity,
# LOCALAI_BACKENDS_PATH for a persistent cache, and enough disk — backends
# can be GB-sized).
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
BACKENDS_DIR=$LOCALAI_DIR/backends
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
ARCH=$(uname -m)
case "$ARCH" in
  x86_64)  LA_ARCH="amd64"  ;;
  aarch64) LA_ARCH="arm64"  ;;
  *) msg_error "Unsupported arch: $ARCH"; exit 250 ;;
esac

if [[ "$LOCALAI_VERSION" == "latest" ]]; then
  TAG=$(curl -fsSL https://api.github.com/repos/mudler/LocalAI/releases/latest | jq -r '.tag_name')
else
  TAG="v${LOCALAI_VERSION#v}"
fi
[[ -z "$TAG" || "$TAG" == "null" ]] && { msg_error "Could not resolve latest LocalAI release"; exit 250; }

# v4 asset naming is fully versioned: local-ai-v4.9.0-linux-amd64
# (the unversioned local-ai-Linux-x86_64 alias no longer exists and 404s).
DL_URL="https://github.com/mudler/LocalAI/releases/download/${TAG}/local-ai-${TAG}-linux-${LA_ARCH}"
msg_info "Downloading LocalAI ${TAG} binary"
mkdir -p "$LOCALAI_DIR" "$MODELS_DIR" "$BACKENDS_DIR"
curl -fsSL "$DL_URL" -o "$LOCALAI_BIN" || { msg_error "Download failed: $DL_URL"; exit 250; }
chmod +x "$LOCALAI_BIN"
msg_ok "LocalAI binary installed at $LOCALAI_BIN"

# ----------------------------------------------------------------------------
# Model configs — chat LLM, image gen (diffusers), embeddings.
# gpu_layers: 99 = "offload what fits", so the same configs serve CPU-only
# and GPU-visible containers.
#
# The diffusers config demonstrates the on-demand backend system: LocalAI
# pulls the diffusers OCI backend automatically the first time a model
# request uses backend: diffusers (no Docker involved — LocalAI fetches and
# runs OCI backend images itself). Backends are GB-sized; disk matters.
# ----------------------------------------------------------------------------
msg_info "Writing model configs to $MODELS_DIR"

cat > "$MODELS_DIR/qwen2.5-3b-chat.yaml" <<'EOF'
name: qwen2.5-3b-chat
backend: llama-cpp
parameters:
  model: huggingface://Qwen/Qwen2.5-3B-Instruct-GGUF/qwen2.5-3b-instruct-q4_k_m.gguf
context_size: 8192
gpu_layers: 99
f16: true
EOF

cat > "$MODELS_DIR/stablediffusion.yaml" <<'EOF'
name: stablediffusion
backend: diffusers
parameters:
  # Direct single-file reference — avoids LocalAI v4's gallery artifact
  # system pulling the ENTIRE DreamShaper repo (20+ GB of XL variants,
  # inpainting models, LoRAs) before the API will start. Swap in a
  # huggingface://<repo> reference if you do want full-repo artifacts.
  model: https://huggingface.co/Lykon/DreamShaper/resolve/main/DreamShaper_8_pruned.safetensors
step: 25
diffusers:
  pipeline_type: StableDiffusionPipeline
  scheduler_type: "k_dpmpp_2m"
EOF

cat > "$MODELS_DIR/embeddings.yaml" <<'EOF'
embeddings: true
name: text-embedding-ada-002
backend: llama-cpp
parameters:
  model: huggingface://bartowski/granite-embedding-107m-multilingual-GGUF/granite-embedding-107m-multilingual-f16.gguf
EOF

msg_ok "Model configs written (models + backends download on first use)"

# ----------------------------------------------------------------------------
# systemd service
# ----------------------------------------------------------------------------
msg_info "Creating systemd service"
cat > /etc/systemd/system/localai.service <<EOF
[Unit]
Description=LocalAI — OpenAI-compatible API (chat/images/embeddings)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=$LOCALAI_DIR
ExecStart=$LOCALAI_BIN run --models-path $MODELS_DIR --address 0.0.0.0:8080
Environment=MODELS_PATH=$MODELS_DIR
# Persist backends (GB-sized OCI extractions) and scratch space outside /tmp
Environment=LOCALAI_BACKENDS_PATH=$BACKENDS_DIR
Environment=LOCALAI_UPLOAD_PATH=$LOCALAI_DIR/upload
Environment=LOCALAI_GENERATED_CONTENT_PATH=$LOCALAI_DIR/generated
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

mkdir -p "$LOCALAI_DIR/upload" "$LOCALAI_DIR/generated"

systemctl daemon-reload
systemctl enable -q --now localai
msg_ok "localai.service enabled"

# Persist deployment mode for the updater
echo "binary" > "$LOCALAI_DIR/deploy-mode"
msg_ok "Deployment mode persisted: binary"

# ----------------------------------------------------------------------------
# Welcome banner — at-a-glance status on every LXC console login.
# ----------------------------------------------------------------------------
cat > /etc/profile.d/localai-banner.sh <<'BANNER'
#!/usr/bin/env bash
# LocalAI status banner — shown on interactive console logins.
localai_banner() {
  [[ $- == *i* ]] || return 0
  local IP CORES CPU_PCT RAM_TOTAL RAM_USED RAM_PCT DISK_TOTAL DISK_USED DISK_PCT
  local SVC_STATUS BACKENDS MODELS GPU_LINE
  IP=$(hostname -I 2>/dev/null | awk '{print $1}')
  CORES=$(nproc)
  CPU_PCT=$(top -bn1 2>/dev/null | grep '^%Cpu' | awk '{print int(100-$8)}')
  CPU_PCT=${CPU_PCT:-?}
  read -r RAM_TOTAL RAM_USED <<< "$(free -m | awk '/^Mem:/{print $2, $3}')"
  if [[ -n "$RAM_TOTAL" && "$RAM_TOTAL" -gt 0 ]]; then
    RAM_PCT=$(( RAM_USED * 100 / RAM_TOTAL ))
    RAM_TOTAL=$(awk -v m="$RAM_TOTAL" 'BEGIN{printf "%.1f", m/1024}')
    RAM_USED=$(awk -v m="$RAM_USED" 'BEGIN{printf "%.1f", m/1024}')
  fi
  read -r DISK_TOTAL DISK_USED DISK_PCT <<< "$(df -h / | awk 'NR==2{print $2, $3, $5}')"
  if systemctl is-active --quiet localai 2>/dev/null; then
    SVC_STATUS="running"
  else
    SVC_STATUS="STOPPED (systemctl start localai)"
  fi
  BACKENDS=0
  [[ -d /opt/localai/backends ]] && BACKENDS=$(find /opt/localai/backends -maxdepth 1 -mindepth 1 -type d 2>/dev/null | wc -l)
  MODELS=$(ls /opt/localai/models/*.yaml 2>/dev/null | wc -l)
  if command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi >/dev/null 2>&1; then
    GPU_LINE="  GPU    : $(nvidia-smi --query-gpu=name,memory.used,memory.total --format=csv,noheader 2>/dev/null | head -1)"
  else
    GPU_LINE="  GPU    : none visible (CPU inference)"
  fi
  echo ""
  cat <<'ART'
    __                     _____    ____
   / /   ____  _________ _/ /   |  /  _/
  / /   / __ \/ ___/ __ `/ / /| |  / /
 / /___/ /_/ / /__/ /_/ / / ___ |_/ /
/_____/\____/\___/\__,_/_/_/  |_/___/
ART
  echo ""
  echo "  URL    : http://${IP}:8080/v1"
  echo "  Web UI : http://${IP}:8080"
  echo "  Service: ${SVC_STATUS}"
  echo "  Models : ${MODELS} configured   Backends: ${BACKENDS} installed"
  echo "  CPU    : ${CORES} cores @ ${CPU_PCT}% usage"
  echo "  RAM    : ${RAM_USED} / ${RAM_TOTAL} GB (${RAM_PCT}%)"
  echo "  Disk   : ${DISK_USED} / ${DISK_TOTAL} (${DISK_PCT})"
  echo "${GPU_LINE}"
  echo ""
  echo "  Config : /opt/localai/models (drop YAMLs — they hot-load)"
  echo "  Update : bash /opt/localai/update.sh"
  echo ""
}
localai_banner
unset -f localai_banner
BANNER
chmod +x /etc/profile.d/localai-banner.sh
msg_ok "Welcome banner installed (/etc/profile.d/localai-banner.sh)"

# Also register as an update-motd fragment so SSH logins show it too
# (profile.d only covers interactive shells; update-motd covers both).
if [[ -d /etc/update-motd.d ]]; then
  cp /etc/profile.d/localai-banner.sh /etc/update-motd.d/99-localai
  chmod +x /etc/update-motd.d/99-localai
  msg_ok "Banner registered in /etc/update-motd.d/ (SSH logins)"
fi

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
