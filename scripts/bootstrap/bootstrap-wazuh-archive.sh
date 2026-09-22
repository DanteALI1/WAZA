#!/usr/bin/env bash
# Bootstrap ВМ wazuh-archive — ДО настройки snapshot repository / ISM.
# ВМ НЕ входит в Kubernetes: только NFS-хранилище снимков.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

VM_ROLE="archive"
HOSTNAME_DEFAULT="wazuh-archive"

usage() {
  cat <<EOF
Использование: sudo $0 [опции]

Подготовка отдельного сервера ARCHIVE (NFS) после установки ОС.
Не устанавливает Kubernetes.

Опции:
  -y, --yes
  -n, --noninteractive
  --data-disk PATH
  --hostname NAME          (default: ${HOSTNAME_DEFAULT})
  --nfs-cidr CIDR          клиенты NFS (default: 10.10.10.0/24)
  -h, --help

Переменные:
  NFS_CLIENT_CIDR   то же что --nfs-cidr
  DATA_DISK         DATA-диск под /mnt/snapshots
EOF
}

HOSTNAME_SET="${HOSTNAME_DEFAULT}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    -y|--yes) ASSUME_YES=1; shift ;;
    -n|--noninteractive) NONINTERACTIVE=1; shift ;;
    --data-disk) DATA_DISK="$2"; shift 2 ;;
    --hostname) HOSTNAME_SET="$2"; shift 2 ;;
    --nfs-cidr) NFS_CLIENT_CIDR="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Неизвестный аргумент: $1"; usage; exit 1 ;;
  esac
done

bootstrap_init "$@"
info "===== BOOTSTRAP ROLE: archive (NFS) ====="

detect_os
print_system_facts
configure_hostname_hosts "${HOSTNAME_SET}"
disable_swap
install_base_packages
create_access_model
# archive не нужен полный k8s sysctl, но max_map_count не мешает; модули overlay не обязательны
begin_stage "Минимальный sysctl для archive"
cat >/etc/sysctl.d/99-wazuh-archive.conf <<'EOF'
net.ipv4.ip_forward = 0
fs.file-max = 65536
EOF
run_cmd "sysctl --system" sysctl --system || warn "sysctl warnings"
end_stage_ok "sysctl archive"
configure_selinux_note
prepare_data_disk "/mnt/snapshots" ""
configure_firewall_interactive "archive"
install_nfs_server_archive

info "ARCHIVE готов. С indexer смонтируйте NFS:"
info "  mount -t nfs ${HOSTNAME_SET}:/mnt/snapshots /mnt/snapshots"
info "Далее: Snapshot repository + daily policy (docs/wazuh-install.md часть 6)"

print_final_report
