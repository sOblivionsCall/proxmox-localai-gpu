#!/usr/bin/env bash
# ============================================================================
# Proxmox VE LXC installer — LocalAI with GPU passthrough (optional)
#
# Modeled on community-scripts/ProxmoxVE (MIT): this is the "ct/*.sh"
# host-side launcher. It creates the LXC, then delegates to
# install/localai-install.sh inside the container.
#
# GPU handling: the community-scripts ENGINE handles GPU passthrough itself
# (detect_gpu_devices() + configure_gpu_passthrough() + fix_gpu_gids() run
# inside create_lxc_container() when var_gpu=yes). We only set var_gpu and
# warn about a missing host driver — we do NOT hand-append device mounts,
# which previously raced and conflicted with the engine's own config writes.
#
# Run from the Proxmox HOST shell:
#   bash -c "$(wget -qLO - https://raw.githubusercontent.com/sOblivionsCall/proxmox-localai-gpu/main/ct/localai.sh)"
#
# Env overrides (advanced):
#   CT_ID=120 CT_NAME=localai bash ct/localai.sh
#   GPU=no      force CPU-only container (unprivileged)
#   GPU=yes     require GPU, fail if none detected
# ============================================================================
APP="LocalAI"
var_tags="${var_tags:-ai}"
var_cpu="${var_cpu:-4}"
var_ram="${var_ram:-8192}"
var_disk="${var_disk:-40}"
var_os="${var_os:-ubuntu}"
var_version="${var_version:-24.04}"
# Nesting is required: the docker deployment path runs Docker inside the LXC.
var_nesting="${var_nesting:-1}"
# Keyctl is required for Docker in unprivileged containers.
var_keyctl="${var_keyctl:-1}"

# ----------------------------------------------------------------------------
# GPU detection (host-side, before container creation)
# ----------------------------------------------------------------------------
detect_host_gpu() {
  if lspci 2>/dev/null | grep -qi 'nvidia'; then
    echo "nvidia"
  elif lspci 2>/dev/null | grep -Eiq 'vga.*amd|amd/ati|radeon' && [[ -e /dev/kfd ]]; then
    echo "amd"
  else
    echo "none"
  fi
}

HOST_GPU="${HOST_GPU:-$(detect_host_gpu)}"
# Explicit override: GPU=no forces CPU-only, GPU=yes requires a GPU.
if [[ "${GPU:-}" == "no" ]]; then
  HOST_GPU="none"
fi

if [[ "$HOST_GPU" == "none" ]]; then
  # CPU-only: unprivileged is both possible and preferred (more secure).
  var_gpu="no"
  var_unprivileged="${var_unprivileged:-1}"
else
  # Engine picks up var_gpu=yes and runs its own configure_gpu_passthrough()
  # + fix_gpu_gids() inside create_lxc_container().
  var_gpu="yes"
  var_unprivileged="${var_unprivileged:-0}"
fi

# ----------------------------------------------------------------------------
# Community-scripts build.func integration (host-side scaffolding).
#
# The engine derives the install-script name from APP: NSAPP=lowercase(APP),
# var_install="${NSAPP}-install" → "localai-install". It fetches that from
# COMMUNITY_SCRIPTS_URL, so the base MUST point at THIS repo — otherwise it
# 404s against ProxmoxVED (which is exactly the failure seen on first run).
# ----------------------------------------------------------------------------
REPO_BASE="${COMMUNITY_SCRIPTS_URL:-https://raw.githubusercontent.com/sOblivionsCall/proxmox-localai-gpu/main}"
export COMMUNITY_SCRIPTS_URL="$REPO_BASE"

if [[ -n "${COMMUNITY_SCRIPTS_CORE_DIR:-}" && -f "$COMMUNITY_SCRIPTS_CORE_DIR/core/build.func" ]]; then
  source "$COMMUNITY_SCRIPTS_CORE_DIR/core/build.func"
  USE_CS_CORE=1
elif curl -fsSL "${COMMUNITY_SCRIPTS_CORE_URL:-https://raw.githubusercontent.com/community-scripts/core/main/core/build.func}" -o /tmp/cs-build.func 2>/dev/null; then
  # shellcheck disable=SC1091
  source /tmp/cs-build.func
  USE_CS_CORE=1
else
  USE_CS_CORE=0
  # Fallback: self-contained minimal scaffolding (no community-scripts dep).
  # shellcheck source=/dev/null
  source "$(dirname "${BASH_SOURCE[0]}")/../core/minimal-build.func"
fi

header_info "$APP"
variables
color
catch_errors

# GPU warning: make sure the host actually has a driver BEFORE building.
pre_install_gpu_check() {
  if [[ "$HOST_GPU" == "none" ]]; then
    if [[ "${GPU:-}" == "yes" ]]; then
      msg_error "GPU=yes requested but no NVIDIA/AMD GPU detected on the host."
      exit 201
    fi
    msg_warn "No discrete GPU detected — building CPU-only LocalAI container."
    msg_warn "Inference will be slow for large models. Set GPU passthrough up and re-run for GPU acceleration."
    return
  fi
  if [[ "$HOST_GPU" == "nvidia" ]] && ! command -v nvidia-smi >/dev/null 2>&1; then
    msg_warn "NVIDIA GPU found but 'nvidia-smi' is not available on the HOST."
    msg_warn "Install the NVIDIA driver on the Proxmox HOST first — the container only gets device nodes + userspace."
    msg_warn "Without a host driver, CUDA will not work and LocalAI falls back to CPU."
    if [[ "$ADVANCED" == "yes" ]]; then
      read -r -p "Continue anyway (CPU-only LocalAI)? [y/N]: " reply
      [[ "$reply" =~ ^[Yy]$ ]] || exit 201
    fi
  fi
  # Ensure UVM devices exist on the host before container creation — the
  # classic silent failure where /dev/nvidia-uvm doesn't exist until the
  # first CUDA client touches it.
  if [[ "$HOST_GPU" == "nvidia" ]] && command -v nvidia-modprobe >/dev/null 2>&1; then
    nvidia-modprobe -u -c=0 >/dev/null 2>&1 || true
  fi
  if [[ "$HOST_GPU" == "nvidia" ]] && command -v crontab >/dev/null 2>&1; then
    (crontab -l 2>/dev/null; echo '@reboot /usr/bin/nvidia-modprobe -u -c=0') | crontab - >/dev/null 2>&1 || true
  fi
}

# In-container GPU sanity check runs INSIDE the LXC (via pct exec) after
# creation — that's where a device-mount failure actually shows up, not at
# container creation time.
# (The engine's fix_gpu_gids() runs inside create_lxc_container() for us.)

# ==============================================================================
# UPDATE SUPPORT
# ==============================================================================
# Re-running the ct script on a host where the LocalAI LXC already exists
# routes here instead of creating a duplicate. Matches the community-scripts
# update_script() convention (called by build_container() / post-install
# helper "Apply updates").
localai_installed_in_ct() {
  pct exec "$CTID" -- bash -c 'systemctl is-active --quiet localai 2>/dev/null || docker ps --format "{{.Names}}" 2>/dev/null | grep -qx localai' >/dev/null 2>&1
}

update_container() {
  msg_info "Updating LocalAI inside CT ${CTID}"
  # DEPLOY_MODE is persisted by the installer into /opt/localai/deploy-mode
  local MODE
  MODE=$(pct exec "$CTID" -- bash -c 'cat /opt/localai/deploy-mode 2>/dev/null || echo docker') || MODE="docker"
  msg_info "Detected deployment mode: ${MODE}"

  if [[ "$MODE" == "docker" ]]; then
    msg_info "Pulling latest LocalAI image"
    pct exec "$CTID" -- docker pull localai/localai:latest-aio-gpu-nvidia-cuda-13 || {
      msg_error "Image pull failed — check connectivity / disk space"
      exit 250
    }
    msg_ok "New image pulled"
    msg_info "Recreating container"
    pct exec "$CTID" -- systemctl restart localai
    msg_ok "Container recreated from the new image"
  else
    msg_info "Re-downloading LocalAI binary"
    pct exec "$CTID" -- bash -c 'DEPLOY_MODE=binary LOCALAI_VERSION=latest bash -s' <<'UPDATE_BINARY'
set -e
ARCH=$(uname -m)
case "$ARCH" in
  x86_64)  LA_OS="Linux";  LA_ARCH="x86_64"  ;;
  aarch64) LA_OS="Linux";  LA_ARCH="arm64"   ;;
  *) echo "unsupported arch $ARCH"; exit 1 ;;
esac
TAG=$(curl -fsSL https://api.github.com/repos/mudler/LocalAI/releases/latest | jq -r '.tag_name')
[[ -z "$TAG" || "$TAG" == "null" ]] && { echo "could not resolve latest"; exit 1; }
DL_URL="https://github.com/mudler/LocalAI/releases/download/${TAG}/local-ai-${LA_OS}-${LA_ARCH}"
curl -fsSL "$DL_URL" -o /usr/local/bin/local-ai.new && chmod +x /usr/local/bin/local-ai.new
mv /usr/local/bin/local-ai.new /usr/local/bin/local-ai
systemctl restart localai
echo "updated to ${TAG}"
UPDATE_BINARY
    msg_ok "Binary updated and service restarted"
  fi

  sleep 8
  if pct exec "$CTID" -- systemctl is-active --quiet localai; then
    msg_ok "LocalAI is running after update"
  else
    msg_error "LocalAI not running after update — check journalctl -u localai in CT ${CTID}"
  fi
}

function update_script() {
  header_info
  check_container_storage
  check_container_resources
  if ! localai_installed_in_ct; then
    msg_error "No LocalAI installation found in CT ${CTID}!"
    exit
  fi
  update_container
  msg_ok "Updated successfully!"
  exit
}

start
pre_install_gpu_check
build_container
description

# Ship the in-container updater now that the container exists (needs
# /opt/localai from the installer) — the installer persisted deploy-mode.
if pct exec "$CTID" -- test -f /opt/localai/deploy-mode >/dev/null 2>&1; then
  pct push "$CTID" "$(cd "$(dirname "${BASH_SOURCE[0]}")/../install" && pwd)/localai-update.sh" /opt/localai/update.sh >/dev/null 2>&1 && \
    pct exec "$CTID" -- chmod +x /opt/localai/update.sh >/dev/null 2>&1 && \
    msg_ok "In-container updater installed: /opt/localai/update.sh"
fi

msg_ok "Completed successfully!\n"
echo -e "${CREATING}${GN}${APP} LXC created — LocalAI is installed and running${CL}"
if [[ "$HOST_GPU" == "none" ]]; then
  echo -e "${INFO}${YW}Mode:${CL} CPU-only (unprivileged container)"
else
  echo -e "${INFO}${YW}Mode:${CL} GPU-accelerated ($HOST_GPU)"
fi
echo -e "${INFO}${YW}LocalAI API:${CL} ${GATEWAY}${BGN}http://${IP}:8080/v1${CL}"
echo -e "${INFO}${YW}Models directory on the container:${CL} ${BGN}/opt/localai/models${CL}"
echo -e "${INFO}${YW}Update later:${CL} re-run this script (update mode), or inside the container: ${BGN}bash /opt/localai/update.sh${CL}"