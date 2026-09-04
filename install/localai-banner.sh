#!/usr/bin/env bash
# LocalAI status banner — dynamic MOTD fragment (update-motd.d).
# Shows at-a-glance status on console/SSH login: service state, URL,
# models/backends installed, CPU/RAM/disk usage, and GPU when visible.

IP=$(hostname -I 2>/dev/null | awk '{print $1}')
CORES=$(nproc)
CPU_PCT=$(top -bn1 2>/dev/null | grep '^%Cpu' | awk '{print int(100-$8)}')
CPU_PCT=${CPU_PCT:-?}

read -r RAM_TOTAL RAM_USED <<< "$(free -m | awk '/^Mem:/{print $2, $3}')"
RAM_PCT=""
if [[ -n "${RAM_TOTAL:-}" && "$RAM_TOTAL" -gt 0 ]]; then
  RAM_PCT=$(( RAM_USED * 100 / RAM_TOTAL ))
  RAM_TOTAL_GB=$(awk -v m="$RAM_TOTAL" 'BEGIN{printf "%.1f", m/1024}')
  RAM_USED_GB=$(awk -v m="$RAM_USED" 'BEGIN{printf "%.1f", m/1024}')
fi

read -r DISK_TOTAL DISK_USED DISK_PCT <<< "$(df -h / | awk 'NR==2{print $2, $3, $5}')"

if systemctl is-active --quiet localai 2>/dev/null; then
  SVC_STATUS="\e[32mrunning\e[0m"
else
  SVC_STATUS="\e[31mSTOPPED\e[0m (systemctl start localai)"
fi

BACKENDS=0
[[ -d /opt/localai/backends ]] && BACKENDS=$(find /opt/localai/backends -maxdepth 1 -mindepth 1 -type d 2>/dev/null | wc -l)
MODELS=$(ls /opt/localai/models/*.yaml 2>/dev/null | wc -l)

if command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi >/dev/null 2>&1; then
  GPU_LINE="GPU    : $(nvidia-smi --query-gpu=name,memory.used,memory.total --format=csv,noheader 2>/dev/null | head -1)"
else
  GPU_LINE="GPU    : none visible (CPU inference)"
fi

echo ""
cat <<'ART'
    _       _         _        ___  ___
   / \   __| | ___ ___| | ___  / _ \/ __|
  / _ \ / _` |/ __/ _ \ |/ _ \| | | \__ \
 / ___ \ (_| | (_|  __/ | (_) | |_| |___/
/_/   \_\__,_|\___\___|_|\___/ \___/|___/
ART
echo ""
echo -e "  URL    : http://${IP}:8080/v1"
echo -e "  Web UI : http://${IP}:8080"
echo -e "  Service: ${SVC_STATUS}"
echo -e "  Models : ${MODELS} configured   Backends: ${BACKENDS} installed"
echo -e "  CPU    : ${CORES} cores @ ${CPU_PCT}% usage"
echo -e "  RAM    : ${RAM_USED_GB:-?} / ${RAM_TOTAL_GB:-?} GB (${RAM_PCT:-?}%)"
echo -e "  Disk   : ${DISK_USED} / ${DISK_TOTAL} (${DISK_PCT})"
echo -e "  ${GPU_LINE}"
echo ""
echo -e "  Config : /opt/localai/models (drop YAMLs — they hot-load)"
echo -e "  Update : bash /opt/localai/update.sh"
echo ""
