#!/usr/bin/env bash
# ============================================================================
# LocalAI updater — run INSIDE the LXC.
#
#   bash /opt/localai/update.sh
#
# Detects the deployment mode (persisted at install time in
# /opt/localai/deploy-mode) and updates accordingly:
#   docker — pulls the latest LocalAI image and restarts the systemd service
#   binary — re-downloads the latest release binary and restarts
#
# Also wired into the CT script's update_script() (host side) so the
# community-scripts post-install helper "Update" option works too.
# ============================================================================
set -e

msg_info() { echo -e "\e[36m[INFO]\e[0m  $*"; }
msg_ok()   { echo -e "\e[32m[ OK ]\e[0m  $*"; }
msg_warn() { echo -e "\e[33m[WARN]\e[0m  $*"; }
msg_error(){ echo -e "\e[31m[FAIL]\e[0m  $*"; }

LOCALAI_DIR=/opt/localai
MODE_FILE=$LOCALAI_DIR/deploy-mode

if [[ ! -f "$MODE_FILE" ]]; then
  msg_error "No deployment record at $MODE_FILE — was LocalAI installed by this installer?"
  exit 1
fi
MODE=$(cat "$MODE_FILE")
msg_info "Deployment mode: ${MODE}"

case "$MODE" in
  docker)
    msg_info "Pulling latest LocalAI image (this can take a while — multi-GB)"
    docker pull localai/localai:latest-aio-gpu-nvidia-cuda-13
    msg_info "Recreating LocalAI container from the new image"
    systemctl restart localai
    sleep 8
    if systemctl is-active --quiet localai; then
      NEW=$(docker inspect localai --format '{{index .Config.Image}}' 2>/dev/null || echo '?')
      msg_ok "Updated — running image: ${NEW}"
    else
      msg_error "Service not running after update — check 'journalctl -u localai' and 'docker logs localai'"
      exit 1
    fi
    ;;
  binary)
    ARCH=$(uname -m)
    case "$ARCH" in
      x86_64)  LA_OS="Linux";  LA_ARCH="x86_64"  ;;
      aarch64) LA_OS="Linux";  LA_ARCH="arm64"   ;;
      *) msg_error "unsupported arch $ARCH"; exit 1 ;;
    esac
    TAG=$(curl -fsSL https://api.github.com/repos/mudler/LocalAI/releases/latest | jq -r '.tag_name')
    [[ -z "$TAG" || "$TAG" == "null" ]] && { msg_error "could not resolve latest release"; exit 1; }
    DL_URL="https://github.com/mudler/LocalAI/releases/download/${TAG}/local-ai-${LA_OS}-${LA_ARCH}"
    msg_info "Downloading ${TAG} binary"
    curl -fsSL "$DL_URL" -o /usr/local/bin/local-ai.new
    chmod +x /usr/local/bin/local-ai.new
    mv /usr/local/bin/local-ai.new /usr/local/bin/local-ai
    systemctl restart localai
    sleep 5
    if systemctl is-active --quiet localai; then
      msg_ok "Updated to ${TAG} — service running"
    else
      msg_error "Service not running after update — check 'journalctl -u localai'"
      exit 1
    fi
    ;;
  *)
    msg_error "Unknown deploy mode: ${MODE}"
    exit 1
    ;;
esac

# Show what's serving
sleep 2
if curl -fsS -m 10 http://localhost:8080/readyz >/dev/null 2>&1; then
  msg_ok "API ready on :8080"
else
  msg_warn "API not answering /readyz yet — models may still be loading"
fi