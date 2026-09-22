#!/usr/bin/env bash
# Bootstrap ВМ k8s-indexer — ДО установки Kubernetes / Wazuh.
# Готовит ОС, диски, пользователей, firewall, sysctl, NFS client mountpoint.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

VM_ROLE="indexer"
HOSTNAME_DEFAULT="k8s-indexer"

usage() {
  cat <<EOF
Использование: sudo $0 [опции]

Подготовка ВМ indexer (control-plane + wazuh-indexer) после установки ОС,
ДО kubeadm / wazuh-kubernetes.

Опции:
  -y, --yes           Отвечать YES на вопросы (осторожно: диск/firewall)
  -n, --noninteractive  Без вопросов (только безопасные default=n где критично)
  --data-disk PATH    Явно указать DATA-диск, напр. /dev/sdb
  --hostname NAME     Имя хоста (default: ${HOSTNAME_DEFAULT})
  -h, --help          Справка

Переменные окружения:
  WAZUH_ADMIN_USER   (default wazuhadmin)
  WAZUH_OPS_USER     (default wazuhops)
  ARCHIVE_NFS_SERVER (default 10.10.10.14)
  DATA_DISK          то же что --data-disk
EOF
}

HOSTNAME_SET="${HOSTNAME_DEFAULT}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    -y|--yes) ASSUME_YES=1; shift ;;
    -n|--noninteractive) NONINTERACTIVE=1; shift ;;
    --data-disk) DATA_DISK="$2"; shift 2 ;;
    --hostname) HOSTNAME_SET="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Неизвестный аргумент: $1"; usage; exit 1 ;;
  esac
done

bootstrap_init "$@"
info "===== BOOTSTRAP ROLE: indexer ====="

detect_os
print_system_facts
configure_hostname_hosts "${HOSTNAME_SET}"
disable_swap
install_base_packages
create_access_model
configure_sysctl_k8s
configure_selinux_note
prepare_data_disk "/data/wazuh" "indexer"
mkdir -p /mnt/snapshots
chown root:wazuh-admins /mnt/snapshots 2>/dev/null || true
chmod 755 /mnt/snapshots
info "Создан /mnt/snapshots (для NFS path.repo)"
configure_firewall_interactive "indexer"
prepare_nfs_client_mount

info "Дополнительно для indexer:"
info "  - vm.max_map_count уже выставлен"
info "  - каталог PVC: /data/wazuh/indexer"
info "  - следующий шаг вручную: containerd + kubeadm (docs/wazuh-install.md часть 5)"

print_final_report
