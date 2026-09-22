#!/usr/bin/env bash
# Bootstrap ВМ k8s-dashboard — ДО установки Kubernetes / Wazuh.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

VM_ROLE="dashboard"
HOSTNAME_DEFAULT="k8s-dashboard"

usage() {
  cat <<EOF
Использование: sudo $0 [опции]

Подготовка ВМ dashboard (UI + Ingress) после установки ОС, ДО kubeadm join.
DATA-диск не требуется.

Опции:
  -y, --yes
  -n, --noninteractive
  --hostname NAME     (default: ${HOSTNAME_DEFAULT})
  -h, --help
EOF
}

HOSTNAME_SET="${HOSTNAME_DEFAULT}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    -y|--yes) ASSUME_YES=1; shift ;;
    -n|--noninteractive) NONINTERACTIVE=1; shift ;;
    --hostname) HOSTNAME_SET="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Неизвестный аргумент: $1"; usage; exit 1 ;;
  esac
done

bootstrap_init "$@"
info "===== BOOTSTRAP ROLE: dashboard ====="

detect_os
print_system_facts
configure_hostname_hosts "${HOSTNAME_SET}"
disable_swap
install_base_packages
create_access_model
configure_sysctl_k8s
configure_selinux_note
configure_firewall_interactive "dashboard"

info "DATA-диск не используется на dashboard"
info "Следующий шаг: containerd + kubeadm join"

print_final_report
