#!/usr/bin/env bash
# Bootstrap ВМ k8s-manager — ДО установки Kubernetes / Wazuh.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

VM_ROLE="manager"
HOSTNAME_DEFAULT="k8s-manager"

usage() {
  cat <<EOF
Использование: sudo $0 [опции]

Подготовка ВМ manager (поды master + worker) после установки ОС, ДО kubeadm join.

Опции:
  -y, --yes
  -n, --noninteractive
  --data-disk PATH
  --hostname NAME     (default: ${HOSTNAME_DEFAULT})
  -h, --help
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
info "===== BOOTSTRAP ROLE: manager ====="

detect_os
print_system_facts
configure_hostname_hosts "${HOSTNAME_SET}"
disable_swap
install_base_packages
create_access_model
configure_sysctl_k8s
configure_selinux_note
prepare_data_disk "/data/wazuh" "manager-master,manager-worker"
configure_firewall_interactive "manager"

info "Каталоги PVC: /data/wazuh/manager-master и /data/wazuh/manager-worker"
info "Следующий шаг: containerd + kubeadm join (docs/wazuh-install.md)"

print_final_report
