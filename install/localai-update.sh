#!/usr/bin/env bash
# ============================================================================
# LocalAI updater — run INSIDE the LXC.
#
#   bash /opt/localai/update.sh
#
# Binary deployment: re-downloads the latest LocalAI release binary, swaps it
# in atomically, restarts the service. Model configs in /opt/localai/models
# are untouched.
# ============================================================================
set -e

msg_info() { echo -e "\e[36m[INFO]\e[0m  $*"; }
msg_ok()   { echo -e "\e[32m[ OK ]\e[0m  $*"; }
msg_error(){ echo -e "\e[31m[FAIL]\e[0m  $*"; }

ARCH=$(uname -m)
case "$ARCH" in
  x86_64)  LA_OS="Linux";  LA_ARCH="x86_64"  ;;
  aarch64) LA_OS="Linux";  LA_ARCH="arm64"   ;;
  *) msg_error "unsupported arch $ARCH"; exit 1 ;;
esac

TAG=$(curl -fsSL https://api.github.com/repos/mudler/LocalAI/releases/latest | jq -r '.tag_name')
[[ -z "$TAG" || "$TAG" == "null" ]] && { msg_error "could not resolve latest release"; exit 1; }

DL_URL="https://github.com/mudler/LocalAI/releases/download/${TAG}/local-ai-${TAG}-linux-${LA_ARCH}"
msg_info "Downloading LocalAI ${TAG}"
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

if curl -fsS -m 10 http://localhost:8080/readyz >/dev/null 2>&1; then
  msg_ok "API ready on :8080"
else
  msg_warn "API not answering /readyz yet — models may still be loading"
fi