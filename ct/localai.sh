#!/usr/bin/env bash
# ============================================================================
# Proxmox VE LXC installer — LocalAI with GPU passthrough (optional)
#
# Modeled on community-scripts/ProxmoxVE (MIT): this is the "ct/*.sh"
# host-side launcher. It creates the LXC, then delegates to
# install/localai-install.sh inside the container.
#
# GPU handling:
#   - Auto: detects NVIDIA/AMD on the host and wires device mounts.
#   - No GPU found (or GPU=no): creates an unprivileged CPU-only container.
#     LocalAI runs CPU inference — slower but fully functional.
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
  var_gpu="yes"
  # Privileged by default for GPU passthrough (device cgroup + bind mounts).
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
}

# ------------------------------------------------------------------------------
# GPU device mounts. MUST run before build_container(): the engine's
# build_container() both creates the container AND runs the in-container
# installer, so devices have to be in the config before that call. Also
# configures var_gpu/var_unprivileged for build.func's container settings.
# ------------------------------------------------------------------------------
configure_gpu_passthrough() {
  # CPU-only containers: nothing to mount, unprivileged is correct.
  [[ "$HOST_GPU" == "none" ]] && return 0

  # Build.func applies var_gpu=... during variables()/build_container() on
  # the current shell state — but the community-scripts engine additionally
  # recognizes var_gpu_instance-style settings only through its own paths.
  # The reliable cross-version approach is direct config appends + a restart
  # of the (already-created) container, which happens below in post-mount.
  local CTConf="/etc/pve/lxc/${CTID}.conf"
  msg_info "Configuring GPU passthrough for CT ${CTID}"
  if [[ "$HOST_GPU" == "nvidia" ]]; then
    cat <<EOF >>"$CTConf"
# NVIDIA GPU passthrough (added by proxmox-localai-gpu)
lxc.cgroup2.devices.allow: c 195:* rwm
lxc.cgroup2.devices.allow: c 234:* rwm
lxc.mount.entry: /dev/nvidia0 dev/nvidia0 none bind,optional,create=file
lxc.mount.entry: /dev/nvidiactl dev/nvidiactl none bind,optional,create=file
lxc.mount.entry: /dev/nvidia-uvm dev/nvidia-uvm none bind,optional,create=file
lxc.mount.entry: /dev/nvidia-uvm-tools dev/nvidia-uvm-tools none bind,optional,create=file
lxc.mount.entry: /dev/nvidia-modeset dev/nvidia-modeset none bind,optional,create=file
EOF
    msg_ok "NVIDIA device mounts added"
    # Ensure UVM exists at host boot even before first CUDA client.
    if command -v crontab >/dev/null 2>&1; then
      (crontab -l 2>/dev/null; echo '@reboot /usr/bin/nvidia-modprobe -u -c=0') | crontab - >/dev/null 2>&1 || true
    fi
  elif [[ "$HOST_GPU" == "amd" ]]; then
    cat <<EOF >>"$CTConf"
# AMD GPU passthrough (added by proxmox-localai-gpu)
lxc.cgroup2.devices.allow: c 226:* rwm
lxc.mount.entry: /dev/kfd dev/kfd none bind,optional,create=file
lxc.mount.entry: /dev/dri dev/dri none bind,optional,create=dir
EOF
    msg_ok "AMD /dev/kfd + /dev/dri mounts added"
  fi
}

# Mounts + restart must happen BEFORE build_container() so the installer
# inside the container can already see the GPU (nvidia-smi checks, CUDA).
pre_create_gpu_mounts() {
  [[ "$HOST_GPU" == "none" ]] && { msg_ok "CPU-only container — no device mounts needed"; return 0; }
  configure_gpu_passthrough
  # Restart so the newly added mounts/cgroup rules take effect. The engine's
  # build_container() starts the container; our config edits need a restart
  # to apply. If the container doesn't exist yet (first run), this is a no-op.
  if pct status "$CTID" >/dev/null 2>&1; then
    pct reboot "$CTID" >/dev/null 2>&1 || true
  fi
  return 0
}


start
pre_install_gpu_check
# GPU mounts happen inside build_container() via our wrapper below.
pre_create_gpu_mounts
build_container
description

msg_ok "Completed successfully!\n"
echo -e "${CREATING}${GN}${APP} LXC created — LocalAI is installing inside...${CL}"
if [[ "$HOST_GPU" == "none" ]]; then
  echo -e "${INFO}${YW}Mode:${CL} CPU-only (unprivileged container)"
else
  echo -e "${INFO}${YW}Mode:${CL} GPU-accelerated ($HOST_GPU)"
fi
echo -e "${INFO}${YW}LocalAI API:${CL} ${GATEWAY}${BGN}http://${IP}:8080/v1${CL}"
echo -e "${INFO}${YW}Models directory on the container:${CL} ${BGN}/opt/localai/models${CL}"
