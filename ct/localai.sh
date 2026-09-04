#!/usr/bin/env bash
# ============================================================================
# Proxmox VE LXC installer — LocalAI (binary; CPU and GPU)
#
# Modeled on community-scripts/ProxmoxVE (MIT): this is the "ct/*.sh"
# host-side launcher. It creates the LXC, then delegates to
# install/localai-install.sh inside the container.
#
# GPU handling (matches the proven community-scripts Ollama LXC pattern):
#   1. The engine (var_gpu=yes) adds dev0..devN device entries for the
#      NVIDIA nodes at container creation.
#   2. We bind-mount the HOST's NVIDIA userspace driver libraries into the
#      container (libcuda, libnvidia-ml, libcudart, ptxjitcompiler,
#      allocator) plus nvidia-smi — the container needs zero CUDA packages
#      and never gets a kernel driver.
#
# Philosophy: the installer provides the working platform. Configuring
# LocalAI is up to the user (drop YAMLs into /opt/localai/models).
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
if [[ "${GPU:-}" == "no" ]]; then
  HOST_GPU="none"
fi

if [[ "$HOST_GPU" == "none" ]]; then
  var_gpu="no"
  var_unprivileged="${var_unprivileged:-1}"
else
  # Engine adds dev0..devN device entries inside create_lxc_container().
  var_gpu="yes"
  var_unprivileged="${var_unprivileged:-0}"
fi

# ----------------------------------------------------------------------------
# Community-scripts build.func integration.
# The engine derives the install-script name from APP (NSAPP=localai,
# var_install=localai-install) and fetches it from COMMUNITY_SCRIPTS_URL,
# which MUST point at this repo.
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
  # shellcheck source=/dev/null
  source "$(dirname "${BASH_SOURCE[0]}")/../core/minimal-build.func"
fi

header_info "$APP"
variables
color
catch_errors

pre_install_gpu_check() {
  if [[ "$HOST_GPU" == "none" ]]; then
    if [[ "${GPU:-}" == "yes" ]]; then
      msg_error "GPU=yes requested but no NVIDIA/AMD GPU detected on the host."
      exit 201
    fi
    msg_warn "No discrete GPU detected — building CPU-only LocalAI container."
    return
  fi
  if [[ "$HOST_GPU" == "nvidia" ]] && ! command -v nvidia-smi >/dev/null 2>&1; then
    msg_warn "NVIDIA GPU found but 'nvidia-smi' is not available on the HOST."
    msg_warn "Install the NVIDIA driver on the Proxmox HOST first — the container gets the host's userspace libs bind-mounted in."
    if [[ "$ADVANCED" == "yes" ]]; then
      read -r -p "Continue anyway (CPU-only LocalAI)? [y/N]: " reply
      [[ "$reply" =~ ^[Yy]$ ]] || exit 201
    fi
  fi
  # Ensure UVM devices exist on the host before container creation.
  if [[ "$HOST_GPU" == "nvidia" ]] && command -v nvidia-modprobe >/dev/null 2>&1; then
    nvidia-modprobe -u -c=0 >/dev/null 2>&1 || true
  fi
  if [[ "$HOST_GPU" == "nvidia" ]] && command -v crontab >/dev/null 2>&1; then
    (crontab -l 2>/dev/null; echo '@reboot /usr/bin/nvidia-modprobe -u -c=0') | crontab - >/dev/null 2>&1 || true
  fi
}

# ==============================================================================
# UPDATE SUPPORT — re-running the ct script on a host where the LocalAI LXC
# already exists routes here instead of creating a duplicate.
# ==============================================================================
localai_installed_in_ct() {
  pct exec "$CTID" -- bash -c 'systemctl is-active --quiet localai 2>/dev/null' >/dev/null 2>&1
}

update_container() {
  msg_info "Updating LocalAI inside CT ${CTID}"
  pct exec "$CTID" -- bash /opt/localai/update.sh
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

# ----------------------------------------------------------------------------
# Post-create: bind-mount the HOST's NVIDIA userspace driver libs into the
# container (the community-scripts Ollama LXC pattern). The container gets
# zero CUDA packages; it uses the host's driver userspace verbatim, which
# also guarantees version match with the host kernel module.
# ----------------------------------------------------------------------------
mount_nvidia_userspace() {
  [[ "$HOST_GPU" != "nvidia" ]] && return 0
  msg_info "Bind-mounting host NVIDIA userspace libs into CT ${CTID}"
  local CTConf="/etc/pve/lxc/${CTID}.conf"
  local LIBDIR="/usr/lib/x86_64-linux-gnu"
  local DRIVER_VER
  DRIVER_VER=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader | head -1 | tr -d ' ')

  # Devices were added by the engine as dev0..devN. Libraries are ours:
  cat <<EOF >>"$CTConf"
lxc.mount.entry: /usr/bin/nvidia-smi usr/bin/nvidia-smi none bind,optional,create=file
lxc.mount.entry: ${LIBDIR}/libcuda.so ${LIBDIR#/}/libcuda.so none bind,optional,create=file
lxc.mount.entry: ${LIBDIR}/libcuda.so.1 ${LIBDIR#/}/libcuda.so.1 none bind,optional,create=file
lxc.mount.entry: ${LIBDIR}/libcuda.so.${DRIVER_VER} ${LIBDIR#/}/libcuda.so.${DRIVER_VER} none bind,optional,create=file
lxc.mount.entry: ${LIBDIR}/libcudart.so.12 ${LIBDIR#/}/libcudart.so.12 none bind,optional,create=file
lxc.mount.entry: ${LIBDIR}/libnvidia-allocator.so.1 ${LIBDIR#/}/libnvidia-allocator.so.1 none bind,optional,create=file
lxc.mount.entry: ${LIBDIR}/libnvidia-ml.so.1 ${LIBDIR#/}/libnvidia-ml.so.1 none bind,optional,create=file
lxc.mount.entry: ${LIBDIR}/libnvidia-ptxjitcompiler.so ${LIBDIR#/}/libnvidia-ptxjitcompiler.so none bind,optional,create=file
lxc.mount.entry: ${LIBDIR}/libnvidia-ptxjitcompiler.so.1 ${LIBDIR#/}/libnvidia-ptxjitcompiler.so.1 none bind,optional,create=file
EOF
  msg_ok "Host NVIDIA userspace libs bind-mounted (driver ${DRIVER_VER})"

  # Restart so the new mount entries take effect.
  msg_info "Restarting CT ${CTID} to apply mounts"
  pct reboot "$CTID" >/dev/null 2>&1 || { pct stop "$CTID" >/dev/null 2>&1; pct start "$CTID" >/dev/null 2>&1; }
  sleep 5
  if pct exec "$CTID" -- nvidia-smi >/dev/null 2>&1; then
    msg_ok "nvidia-smi works inside the container — GPU visible"
  else
    msg_warn "nvidia-smi still not functional inside the container (LocalAI will run CPU-only)"
  fi
}
mount_nvidia_userspace

# Ship the in-container updater now that the container exists.
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
  echo -e "${INFO}${YW}Mode:${CL} GPU passthrough via the installer engine ($HOST_GPU)"
fi
echo -e "${INFO}${YW}LocalAI API:${CL} ${GATEWAY}${BGN}http://${IP}:8080/v1${CL}"
echo -e "${INFO}${YW}Models directory on the container:${CL} ${BGN}/opt/localai/models${CL}"
echo -e "${INFO}${YW}Update later:${CL} re-run this script (update mode), or inside the container: ${BGN}bash /opt/localai/update.sh${CL}"