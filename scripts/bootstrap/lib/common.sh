#!/usr/bin/env bash
# Общая библиотека bootstrap ВМ Wazuh/K8s.
# shellcheck disable=SC2034,SC2155

set -o errtrace

BOOTSTRAP_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOOTSTRAP_ROOT="$(cd "${BOOTSTRAP_LIB_DIR}/.." && pwd)"

: "${LOG_DIR:=/var/log/wazuh-bootstrap}"
: "${REPORT_FILE:=${LOG_DIR}/bootstrap-report-$(date +%Y%m%d-%H%M%S).txt}"
: "${DEBUG_FILE:=${LOG_DIR}/bootstrap-debug-$(date +%Y%m%d-%H%M%S).log}"
: "${NONINTERACTIVE:=0}"
: "${ASSUME_YES:=0}"

STAGE_NUM=0
STAGE_FAILED=0
STAGE_SKIPPED=0
STAGE_OK=0
declare -a STAGE_SUMMARY=()

# ---- цвета ----
if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'
  C_RED=$'\033[31m'; C_CYAN=$'\033[36m'; C_BOLD=$'\033[1m'
else
  C_RESET=; C_GREEN=; C_YELLOW=; C_RED=; C_CYAN=; C_BOLD=
fi

_ts() { date '+%Y-%m-%d %H:%M:%S'; }

_ensure_log_dir() {
  mkdir -p "${LOG_DIR}" 2>/dev/null || true
  chmod 750 "${LOG_DIR}" 2>/dev/null || true
}

log() {
  local level="$1"; shift
  local msg="$*"
  local line="[$(_ts)] [${level}] ${msg}"
  echo "${line}" | tee -a "${REPORT_FILE}" >/dev/null
  case "${level}" in
    INFO)  echo "${C_CYAN}${line}${C_RESET}" ;;
    OK)    echo "${C_GREEN}${line}${C_RESET}" ;;
    WARN)  echo "${C_YELLOW}${line}${C_RESET}" ;;
    ERROR|DEBUG) echo "${C_RED}${line}${C_RESET}" ;;
    STAGE) echo "${C_BOLD}${C_CYAN}${line}${C_RESET}" ;;
    *)     echo "${line}" ;;
  esac
  echo "${line}" >>"${DEBUG_FILE}"
}

info()  { log INFO "$*"; }
ok()    { log OK "$*"; }
warn()  { log WARN "$*"; }
error() { log ERROR "$*"; }
debug() { log DEBUG "$*"; }

die() {
  error "$*"
  error "Смотрите DEBUG: ${DEBUG_FILE}"
  error "Отчёт: ${REPORT_FILE}"
  exit 1
}

require_root() {
  if [[ "$(id -u)" -ne 0 ]]; then
    echo "Запустите скрипт от root: sudo $0 $*" >&2
    exit 1
  fi
}

ask_yes_no() {
  local prompt="$1"
  local default="${2:-n}"
  if [[ "${ASSUME_YES}" == "1" ]]; then
    info "Авто-ответ YES на: ${prompt}"
    return 0
  fi
  if [[ "${NONINTERACTIVE}" == "1" ]]; then
    if [[ "${default}" == "y" ]]; then return 0; else return 1; fi
  fi
  local hint="[y/N]"
  [[ "${default}" == "y" ]] && hint="[Y/n]"
  local ans
  while true; do
    read -r -p "${prompt} ${hint} " ans || ans=""
    ans="${ans:-$default}"
    case "${ans}" in
      y|Y|yes|YES) return 0 ;;
      n|N|no|NO) return 1 ;;
      *) echo "Введите y или n" ;;
    esac
  done
}

begin_stage() {
  STAGE_NUM=$((STAGE_NUM + 1))
  local title="$1"
  echo
  log STAGE "===== ЭТАП ${STAGE_NUM}: ${title} ====="
  CURRENT_STAGE="${title}"
}

end_stage_ok() {
  local detail="${1:-выполнено}"
  STAGE_OK=$((STAGE_OK + 1))
  STAGE_SUMMARY+=("OK  | ${CURRENT_STAGE} | ${detail}")
  ok "Этап «${CURRENT_STAGE}»: ${detail}"
}

end_stage_skip() {
  local detail="${1:-пропущено}"
  STAGE_SKIPPED=$((STAGE_SKIPPED + 1))
  STAGE_SUMMARY+=("SKIP| ${CURRENT_STAGE} | ${detail}")
  warn "Этап «${CURRENT_STAGE}»: ${detail}"
}

end_stage_fail() {
  local detail="${1:-ошибка}"
  STAGE_FAILED=$((STAGE_FAILED + 1))
  STAGE_SUMMARY+=("FAIL| ${CURRENT_STAGE} | ${detail}")
  error "Этап «${CURRENT_STAGE}»: ${detail}"
}

# Выполнить команду с полным дебагом при ошибке
run_cmd() {
  local desc="$1"; shift
  info "Команда: ${desc}"
  debug "+ $*"
  local out_file rc
  out_file="$(mktemp)"
  set +e
  "$@" >"${out_file}" 2>&1
  rc=$?
  set -e
  cat "${out_file}" >>"${DEBUG_FILE}"
  if [[ ${rc} -ne 0 ]]; then
    error "FAIL (${rc}): ${desc}"
    error "Команда: $*"
    error "----- вывод (хвост) -----"
    tail -n 40 "${out_file}" | while IFS= read -r line; do error "  | ${line}"; done
    error "----- конец вывода -----"
    rm -f "${out_file}"
    return "${rc}"
  fi
  # краткий stdout в отчёт
  if [[ -s "${out_file}" ]]; then
    local lines
    lines="$(wc -l <"${out_file}" | tr -d ' ')"
    info "Успех (${desc}), строк вывода: ${lines} (полный лог в DEBUG)"
    head -n 5 "${out_file}" | while IFS= read -r line; do info "  > ${line}"; done
    [[ "${lines}" -gt 5 ]] && info "  > … ещё $((lines - 5)) строк в ${DEBUG_FILE}"
  else
    ok "Успех (${desc}), вывод пуст"
  fi
  rm -f "${out_file}"
  return 0
}

detect_os() {
  begin_stage "Определение ОС"
  if [[ ! -f /etc/os-release ]]; then
    end_stage_fail "нет /etc/os-release"
    die "Не удалось определить ОС"
  fi
  # shellcheck source=/dev/null
  . /etc/os-release
  OS_ID="${ID:-unknown}"
  OS_VERSION_ID="${VERSION_ID:-unknown}"
  OS_NAME="${PRETTY_NAME:-$OS_ID}"
  OS_FAMILY="unknown"

  case "${OS_ID}" in
    rhel|centos|rocky|almalinux|ol)
      OS_FAMILY="rhel" ;;
    redos|REDOS|red-os)
      OS_FAMILY="rhel" ;;
    astra|astralinux)
      OS_FAMILY="debian" ;;
    debian|ubuntu)
      OS_FAMILY="debian" ;;
  esac

  # РЕД ОС часто ID=redos или подобное
  if grep -qiE 'red.?os|ред.?ос' /etc/os-release 2>/dev/null; then
    OS_FAMILY="rhel"
    OS_ID="redos"
  fi
  if grep -qi 'astra' /etc/os-release 2>/dev/null; then
    OS_FAMILY="debian"
    OS_ID="astra"
  fi

  info "ОС: ${OS_NAME}"
  info "ID=${OS_ID} VERSION=${OS_VERSION_ID} FAMILY=${OS_FAMILY}"
  if [[ "${OS_FAMILY}" == "unknown" ]]; then
    end_stage_fail "неподдерживаемая ОС"
    die "Поддерживаются РЕД ОС 8 (RHEL-like) и Astra Linux SE 1.7/1.8"
  fi
  end_stage_ok "FAMILY=${OS_FAMILY}"
}

print_system_facts() {
  begin_stage "Сбор данных о системе (инвентаризация)"
  info "Hostname: $(hostname -f 2>/dev/null || hostname)"
  info "Kernel: $(uname -r)"
  info "Arch: $(uname -m)"
  info "CPU: $(nproc) vCPU"
  info "RAM: $(free -h | awk '/Mem:/{print $2}')"
  info "Swap: $(free -h | awk '/Swap:/{print $2}')"
  info "Disks:"
  lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT | while IFS= read -r l; do info "  ${l}"; done
  info "Network:"
  ip -br addr 2>/dev/null | while IFS= read -r l; do info "  ${l}"; done || true
  info "Default route: $(ip route show default 2>/dev/null | head -1 || echo none)"
  end_stage_ok "инвентаризация записана в отчёт"
}

configure_hostname_hosts() {
  local desired_host="$1"
  begin_stage "Hostname и /etc/hosts"
  run_cmd "hostnamectl set-hostname ${desired_host}" hostnamectl set-hostname "${desired_host}" || {
    end_stage_fail "hostnamectl"
    return 1
  }
  local hosts_block
  hosts_block="$(cat <<EOF
127.0.0.1 localhost
10.10.10.11 k8s-indexer
10.10.10.12 k8s-manager
10.10.10.13 k8s-dashboard
10.10.10.14 wazuh-archive
EOF
)"
  if ask_yes_no "Записать шаблон /etc/hosts (10.10.10.11–14)? Проверьте IP под свою сеть." "y"; then
    cp -a /etc/hosts "/etc/hosts.bak.$(_ts | tr -d ' :-')"
    # сохранить прочие строки без старых k8s-*
    grep -vE 'k8s-indexer|k8s-manager|k8s-dashboard|wazuh-archive|^127\.0\.0\.1[[:space:]]+localhost' /etc/hosts > /tmp/hosts.rest.$$ || true
    {
      echo "${hosts_block}"
      echo
      cat /tmp/hosts.rest.$$ 2>/dev/null || true
    } >/etc/hosts
    rm -f /tmp/hosts.rest.$$
    ok "Записан /etc/hosts (backup рядом). Сделано: шаблон имён кластера."
  else
    warn "Пропуск записи /etc/hosts — настройте вручную"
  fi
  end_stage_ok "hostname=${desired_host}"
}

disable_swap() {
  begin_stage "Отключение swap (обязательно для K8s; на archive тоже рекомендуется)"
  run_cmd "swapoff -a" swapoff -a || true
  if grep -qE '^[^#].*\sswap\s' /etc/fstab 2>/dev/null; then
    cp -a /etc/fstab "/etc/fstab.bak.$(_ts | tr -d ' :-')"
    sed -ri 's/^([^#].*\sswap\s)/#\1/' /etc/fstab
    ok "Закомментированы swap-строки в /etc/fstab"
  else
    info "В /etc/fstab активных swap нет"
  fi
  local sw
  sw="$(free -h | awk '/Swap:/{print $2}')"
  info "Текущий Swap: ${sw}"
  end_stage_ok "swap отключён"
}

configure_sysctl_k8s() {
  begin_stage "sysctl и модули ядра (overlay, br_netfilter, vm.max_map_count)"
  cat >/etc/modules-load.d/k8s.conf <<'EOF'
overlay
br_netfilter
EOF
  run_cmd "modprobe overlay" modprobe overlay || { end_stage_fail "modprobe overlay"; return 1; }
  run_cmd "modprobe br_netfilter" modprobe br_netfilter || { end_stage_fail "modprobe br_netfilter"; return 1; }
  cat >/etc/sysctl.d/99-kubernetes-cri.conf <<'EOF'
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
vm.max_map_count                    = 262144
fs.file-max                         = 65536
EOF
  run_cmd "sysctl --system" sysctl --system || { end_stage_fail "sysctl"; return 1; }
  local mmc
  mmc="$(sysctl -n vm.max_map_count)"
  info "vm.max_map_count=${mmc} (нужно 262144 для indexer)"
  [[ "${mmc}" == "262144" ]] || warn "max_map_count не 262144 — проверьте"
  end_stage_ok "sysctl применён"
}

install_base_packages() {
  begin_stage "Установка базовых пакетов под роль"
  case "${OS_FAMILY}" in
    rhel)
      run_cmd "dnf -y update (может занять время)" dnf -y update || warn "dnf update завершился с ошибкой — продолжаем с осторожностью"
      run_cmd "dnf install base tools" dnf -y install \
        curl wget tar git chrony ca-certificates yum-utils \
        device-mapper-persistent-data lvm2 conntrack-tools iptables \
        iproute-tc socat ebtables ethtool nfs-utils openssl \
        open-vm-tools sudo python3 which findutils \
        || { end_stage_fail "dnf install"; return 1; }
      run_cmd "enable chronyd" systemctl enable --now chronyd || warn "chronyd не стартовал"
      run_cmd "enable vmtoolsd" systemctl enable --now vmtoolsd || warn "vmtoolsd опционален"
      ;;
    debian)
      run_cmd "apt-get update" apt-get update || { end_stage_fail "apt update"; return 1; }
      run_cmd "apt-get upgrade" DEBIAN_FRONTEND=noninteractive apt-get -y upgrade || warn "upgrade с предупреждениями"
      run_cmd "apt install base tools" DEBIAN_FRONTEND=noninteractive apt-get -y install \
        curl wget tar git ca-certificates apt-transport-https gnupg \
        lsb-release chrony conntrack iptables iproute2 socat ebtables ethtool \
        nfs-common openssl open-vm-tools sudo python3 \
        || { end_stage_fail "apt install"; return 1; }
      # NFS server только на archive — отдельным этапом
      run_cmd "enable chrony" systemctl enable --now chrony || systemctl enable --now chronyd || warn "chrony"
      systemctl enable --now open-vm-tools 2>/dev/null || true
      ;;
  esac
  end_stage_ok "базовые пакеты установлены"
}

# ---- пользователи и RBAC на хосте ----
create_access_model() {
  begin_stage "Пользователи, группы и разграничение доступа"
  local admin_user="${WAZUH_ADMIN_USER:-wazuhadmin}"
  local ops_user="${WAZUH_OPS_USER:-wazuhops}"
  local admin_group="wazuh-admins"
  local ops_group="wazuh-operators"

  run_cmd "groupadd ${admin_group}" groupadd -f "${admin_group}"
  run_cmd "groupadd ${ops_group}" groupadd -f "${ops_group}"

  if ! id "${admin_user}" &>/dev/null; then
    run_cmd "useradd ${admin_user}" useradd -m -s /bin/bash -G "${admin_group}" "${admin_user}" \
      || { end_stage_fail "useradd admin"; return 1; }
    ok "Создан пользователь ${admin_user} (группа ${admin_group})"
    if ask_yes_no "Задать пароль для ${admin_user} сейчас?" "y"; then
      passwd "${admin_user}" || warn "passwd не задан"
    else
      warn "Пароль ${admin_user} не задан — задайте вручную: passwd ${admin_user}"
    fi
  else
    usermod -aG "${admin_group}" "${admin_user}" || true
    info "Пользователь ${admin_user} уже существует — добавлен в ${admin_group}"
  fi

  if ! id "${ops_user}" &>/dev/null; then
    run_cmd "useradd ${ops_user}" useradd -m -s /bin/bash -G "${ops_group}" "${ops_user}" \
      || { end_stage_fail "useradd ops"; return 1; }
    ok "Создан пользователь ${ops_user} (группа ${ops_group})"
    if ask_yes_no "Задать пароль для ${ops_user} сейчас?" "n"; then
      passwd "${ops_user}" || true
    fi
  else
    usermod -aG "${ops_group}" "${ops_user}" || true
    info "Пользователь ${ops_user} уже существует"
  fi

  # sudoers
  cat >/etc/sudoers.d/wazuh-admins <<EOF
# Wazuh bootstrap — полные права админам контура
%${admin_group} ALL=(ALL) ALL
Defaults:%${admin_group} !requiretty
EOF
  chmod 440 /etc/sudoers.d/wazuh-admins
  if visudo -cf /etc/sudoers.d/wazuh-admins; then
    ok "sudoers wazuh-admins: полный sudo. Сделано: /etc/sudoers.d/wazuh-admins"
  else
    rm -f /etc/sudoers.d/wazuh-admins
    end_stage_fail "sudoers invalid"
    return 1
  fi

  cat >/etc/sudoers.d/wazuh-operators <<EOF
# Операторы: только диагностика, без произвольного root
%${ops_group} ALL=(root) NOPASSWD: /usr/bin/journalctl, /usr/bin/systemctl status *, /usr/bin/systemctl is-active *, /bin/ls, /usr/bin/df, /usr/bin/free, /usr/bin/ss, /usr/sbin/iptables -L *
Defaults:%${ops_group} !requiretty
EOF
  chmod 440 /etc/sudoers.d/wazuh-operators
  if visudo -cf /etc/sudoers.d/wazuh-operators; then
    ok "sudoers wazuh-operators: ограниченный sudo на диагностику"
  else
    rm -f /etc/sudoers.d/wazuh-operators
    warn "sudoers operators отклонён — удалено"
  fi

  # SSH keys dir
  for u in "${admin_user}" "${ops_user}"; do
    local home
    home="$(getent passwd "${u}" | cut -d: -f6)"
    mkdir -p "${home}/.ssh"
    chmod 700 "${home}/.ssh"
    touch "${home}/.ssh/authorized_keys"
    chmod 600 "${home}/.ssh/authorized_keys"
    chown -R "${u}:${u}" "${home}/.ssh"
    info "Подготовлен ${home}/.ssh/authorized_keys — положите туда публичный ключ"
  done

  info "Модель доступа:"
  info "  ${admin_user} ∈ ${admin_group} → полный sudo"
  info "  ${ops_user} ∈ ${ops_group} → только диагностика через sudo"
  info "  root — аварийный доступ; повседневная работа — под ${admin_user}"
  end_stage_ok "RBAC хоста создан"
}

prepare_data_disk() {
  # $1 mountpoint  $2 subdirs (comma)  $3 role owner hint
  local mountpoint="$1"
  local subdirs_csv="${2:-}"
  local fs_type="xfs"
  [[ "${OS_FAMILY}" == "debian" ]] && fs_type="ext4"

  begin_stage "Подготовка DATA-диска → ${mountpoint}"

  info "Текущие блочные устройства:"
  lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT | while IFS= read -r l; do info "  ${l}"; done

  local disk=""
  if [[ -n "${DATA_DISK:-}" ]]; then
    disk="${DATA_DISK}"
  else
    # эвристика: первый диск без разделов/mount кроме системного
    local candidates
    candidates="$(lsblk -dn -o NAME,TYPE | awk '$2=="disk"{print $1}')"
    for d in ${candidates}; do
      local mp
      mp="$(lsblk -n -o MOUNTPOINT "/dev/${d}" | tr -d ' ' | grep -v '^$' | head -1 || true)"
      if [[ -z "${mp}" ]] && ! lsblk -n -o MOUNTPOINT "/dev/${d}" | grep -q '/$'; then
        # нет смонтированных разделов на корне
        if ! findmnt -n -S "/dev/${d}" &>/dev/null; then
          local has_part
          has_part="$(lsblk -n -o NAME,TYPE "/dev/${d}" | awk '$2=="part"{print $1}' | wc -l)"
          # пропускаем диск с уже смонтированным /
          if ! lsblk "/dev/${d}" | grep -q ' /$'; then
            if [[ "$(findmnt -no SOURCE /)" != /dev/${d}* ]]; then
              disk="/dev/${d}"
              # предпочитаем диск без partition table / один диск кроме sda
              if [[ "${d}" != "sda" && "${d}" != "nvme0n1" && "${d}" != "vda" ]]; then
                break
              fi
              if [[ "${has_part}" == "0" ]]; then
                break
              fi
            fi
          fi
        fi
      fi
    done
  fi

  if [[ -z "${disk}" ]]; then
    warn "Автоопределение DATA-диска не удалось"
    echo -n "Укажите DATA-диск (например /dev/sdb) или Enter чтобы ПРОПУСТИТЬ: "
    read -r disk || disk=""
    [[ -z "${disk}" ]] && { end_stage_skip "диск не указан"; return 0; }
  fi

  info "Выбран диск: ${disk}"
  if ! ask_yes_no "ВАЖНО: будут созданы GPT+partition и mkfs на ${disk}. ВСЕ ДАННЫЕ НА ДИСКЕ БУДУТ УНИЧТОЖЕНЫ. Продолжить?" "n"; then
    end_stage_skip "пользователь отказался от разметки ${disk}"
    return 0
  fi

  if findmnt -n "${mountpoint}" &>/dev/null; then
    warn "${mountpoint} уже смонтирован — пропускаем mkfs"
  else
    run_cmd "parted mklabel+mkpart" parted "${disk}" --script mklabel gpt mkpart primary "${fs_type}" 1MiB 100% \
      || { end_stage_fail "parted"; return 1; }
    sleep 2
    partprobe "${disk}" 2>/dev/null || true
    local part="${disk}1"
    [[ "${disk}" == *nvme* || "${disk}" == *mmc* ]] && part="${disk}p1"
    # если parted назвал иначе
    if [[ ! -b "${part}" ]]; then
      part="$(lsblk -ln -o NAME,TYPE "${disk}" | awk '$2=="part"{print "/dev/"$1; exit}')"
    fi
    info "Раздел: ${part}"
    if [[ "${fs_type}" == "xfs" ]]; then
      run_cmd "mkfs.xfs" mkfs.xfs -f "${part}" || { end_stage_fail "mkfs"; return 1; }
    else
      run_cmd "mkfs.ext4" mkfs.ext4 -F "${part}" || { end_stage_fail "mkfs"; return 1; }
    fi
    mkdir -p "${mountpoint}"
    local uuid
    uuid="$(blkid -s UUID -o value "${part}")"
    cp -a /etc/fstab "/etc/fstab.bak.$(_ts | tr -d ' :-')"
    grep -v " ${mountpoint} " /etc/fstab > /tmp/fstab.new.$$ || cp /etc/fstab /tmp/fstab.new.$$
    echo "UUID=${uuid} ${mountpoint} ${fs_type} defaults,noatime 0 0" >> /tmp/fstab.new.$$
    mv /tmp/fstab.new.$$ /etc/fstab
    run_cmd "mount -a" mount -a || { end_stage_fail "mount"; return 1; }
    ok "Сделано: GPT, ${part} ${fs_type}, fstab UUID=${uuid}, mount ${mountpoint}"
  fi

  mkdir -p "${mountpoint}"
  if [[ -n "${subdirs_csv}" ]]; then
    IFS=',' read -ra dirs <<<"${subdirs_csv}"
    for d in "${dirs[@]}"; do
      mkdir -p "${mountpoint}/${d}"
      info "Каталог: ${mountpoint}/${d}"
    done
  fi

  # права: admins rwx, operators rx
  chown root:wazuh-admins "${mountpoint}" 2>/dev/null || chown root:root "${mountpoint}"
  chmod 2770 "${mountpoint}" 2>/dev/null || chmod 755 "${mountpoint}"
  if [[ -d "${mountpoint}" ]]; then
    find "${mountpoint}" -type d -exec chmod 2770 {} \; 2>/dev/null || true
    find "${mountpoint}" -type d -exec chown root:wazuh-admins {} \; 2>/dev/null || true
  fi
  ok "Права на ${mountpoint}: root:wazuh-admins 2770 (setgid)"
  df -h "${mountpoint}" | while IFS= read -r l; do info "  ${l}"; done
  end_stage_ok "DATA готов: ${mountpoint}"
}

configure_firewall_interactive() {
  local role="$1"
  begin_stage "Firewall (интерактивно)"

  echo
  info "Планируемые правила для роли «${role}»:"
  case "${role}" in
    indexer)
      info "  TCP: 22, 6443, 2379-2380, 10250, 179, 1514, 1515, 443, 30000-32767, 2049(NFS client)"
      info "  UDP: 4789 (Calico VXLAN)"
      ;;
    manager)
      info "  TCP: 22, 10250, 179, 1514, 1515, 443, 30000-32767"
      info "  UDP: 4789"
      ;;
    dashboard)
      info "  TCP: 22, 10250, 179, 443, 30000-32767"
      info "  UDP: 4789"
      ;;
    archive)
      info "  TCP: 22, 2049 (NFS), rpcbind/mountd"
      info "  Разрешить NFS только с сети 10.10.10.0/24 (уточните)"
      ;;
  esac

  if ! ask_yes_no "Применить эти правила firewall сейчас?" "y"; then
    end_stage_skip "firewall не менялся по выбору пользователя"
    return 0
  fi

  case "${OS_FAMILY}" in
    rhel)
      run_cmd "enable firewalld" systemctl enable --now firewalld || { end_stage_fail "firewalld"; return 1; }
      local ports=(22/tcp 6443/tcp 10250/tcp 179/tcp 1514/tcp 1515/tcp 443/tcp 2049/tcp)
      local p
      for p in "${ports[@]}"; do
        firewall-cmd --permanent --add-port="${p}" && info "  + permanent port ${p}"
      done
      firewall-cmd --permanent --add-port=2379-2380/tcp
      firewall-cmd --permanent --add-port=30000-32767/tcp
      firewall-cmd --permanent --add-port=4789/udp
      if [[ "${role}" == "archive" || "${role}" == "indexer" ]]; then
        firewall-cmd --permanent --add-service=nfs || true
        firewall-cmd --permanent --add-service=rpc-bind || true
        firewall-cmd --permanent --add-service=mountd || true
        info "  + services nfs, rpc-bind, mountd"
      fi
      run_cmd "firewall-cmd --reload" firewall-cmd --reload || { end_stage_fail "reload"; return 1; }
      info "Активные зоны:"
      firewall-cmd --list-all 2>/dev/null | while IFS= read -r l; do info "  ${l}"; done
      ok "Сделано: firewalld permanent rules + reload"
      ;;
    debian)
      run_cmd "install ufw" DEBIAN_FRONTEND=noninteractive apt-get -y install ufw || true
      ufw allow 22/tcp
      case "${role}" in
        indexer)
          ufw allow 6443/tcp; ufw allow 2379:2380/tcp; ufw allow 10250/tcp
          ufw allow 179/tcp; ufw allow 4789/udp; ufw allow 1514:1515/tcp
          ufw allow 443/tcp; ufw allow 2049/tcp; ufw allow 30000:32767/tcp
          ;;
        manager)
          ufw allow 10250/tcp; ufw allow 179/tcp; ufw allow 4789/udp
          ufw allow 1514:1515/tcp; ufw allow 443/tcp; ufw allow 30000:32767/tcp
          ;;
        dashboard)
          ufw allow 10250/tcp; ufw allow 179/tcp; ufw allow 4789/udp
          ufw allow 443/tcp; ufw allow 30000:32767/tcp
          ;;
        archive)
          ufw allow 2049/tcp
          ufw allow from 10.10.10.0/24 to any port 2049 proto tcp || true
          ;;
      esac
      if ask_yes_no "Включить ufw --force enable (может разорвать SSH если 22 не открыт)?" "y"; then
        ufw --force enable
        ok "Сделано: ufw enabled с правилами роли ${role}"
      else
        warn "Правила добавлены, но ufw не включён"
      fi
      ufw status verbose 2>/dev/null | while IFS= read -r l; do info "  ${l}"; done
      ;;
  esac
  end_stage_ok "firewall обработан"
}

configure_selinux_note() {
  begin_stage "SELinux / MAC (информация и опционально)"
  if command -v getenforce &>/dev/null; then
    local mode
    mode="$(getenforce)"
    info "SELinux: ${mode}"
    if [[ "${mode}" == "Enforcing" ]]; then
      warn "Enforcing OK для production, но может блокировать containerd/kubelet/NFS"
      if ask_yes_no "Временно перевести SELinux в Permissive (только для отладки)?" "n"; then
        setenforce 0 || true
        sed -i 's/^SELINUX=enforcing/SELINUX=permissive/' /etc/selinux/config 2>/dev/null || true
        ok "Сделано: SELinux Permissive (setenforce 0 + config). Верните Enforcing после стабилизации."
      else
        info "SELinux оставлен Enforcing — при CreateContainerError смотрите ausearch"
      fi
    fi
  else
    info "SELinux нет (типично для Astra — используйте политики ЗПС/MAC по регламенту ИБ)"
    warn "На Astra: до K8s согласуйте исключения MAC для containerd/kubelet/NFS"
  fi
  end_stage_ok "MAC/SELinux этап завершён"
}

install_nfs_server_archive() {
  begin_stage "NFS server на ARCHIVE"
  local export_dir="/mnt/snapshots"
  local cidr="${NFS_CLIENT_CIDR:-10.10.10.0/24}"

  case "${OS_FAMILY}" in
    rhel)
      run_cmd "install nfs-utils" dnf -y install nfs-utils || { end_stage_fail "nfs-utils"; return 1; }
      ;;
    debian)
      run_cmd "install nfs-kernel-server" DEBIAN_FRONTEND=noninteractive apt-get -y install nfs-kernel-server \
        || { end_stage_fail "nfs-kernel-server"; return 1; }
      ;;
  esac

  mkdir -p "${export_dir}"
  # uid 1000 — типичный wazuh-indexer в контейнере
  if ask_yes_no "Выставить владельца ${export_dir} на 1000:1000 (под контейнер indexer)?" "y"; then
    chown -R 1000:1000 "${export_dir}"
    chmod 755 "${export_dir}"
    ok "Сделано: chown 1000:1000 ${export_dir}"
  else
    chown root:wazuh-admins "${export_dir}" 2>/dev/null || true
    chmod 2775 "${export_dir}"
    warn "Оставлены права root:wazuh-admins — при Snapshot FAIL вернитесь к 1000:1000"
  fi

  echo "${export_dir} ${cidr}(rw,sync,no_root_squash,no_subtree_check)" >/etc/exports
  info "Записан /etc/exports: ${export_dir} → ${cidr} (rw,sync,no_root_squash,no_subtree_check)"

  if [[ "${OS_FAMILY}" == "rhel" ]]; then
    run_cmd "enable nfs-server" systemctl enable --now nfs-server || { end_stage_fail "nfs-server"; return 1; }
  else
    run_cmd "enable nfs-kernel-server" systemctl enable --now nfs-kernel-server || { end_stage_fail "nfs"; return 1; }
  fi
  run_cmd "exportfs -rav" exportfs -rav || { end_stage_fail "exportfs"; return 1; }
  exportfs -v 2>/dev/null | while IFS= read -r l; do info "  ${l}"; done
  end_stage_ok "NFS export опубликован"
}

prepare_nfs_client_mount() {
  begin_stage "Подготовка клиента NFS (/mnt/snapshots) на indexer"
  mkdir -p /mnt/snapshots
  local server="${ARCHIVE_NFS_SERVER:-10.10.10.14}"
  if ask_yes_no "Смонтировать ${server}:/mnt/snapshots → /mnt/snapshots сейчас? (NFS server уже должен работать)" "n"; then
    case "${OS_FAMILY}" in
      rhel) run_cmd "install nfs-utils" dnf -y install nfs-utils || true ;;
      debian) run_cmd "install nfs-common" DEBIAN_FRONTEND=noninteractive apt-get -y install nfs-common || true ;;
    esac
    if run_cmd "mount nfs" mount -t nfs "${server}:/mnt/snapshots" /mnt/snapshots; then
      if ! grep -q '/mnt/snapshots' /etc/fstab; then
        echo "${server}:/mnt/snapshots /mnt/snapshots nfs defaults,_netdev,noatime 0 0" >>/etc/fstab
        ok "Сделано: mount + строка fstab"
      fi
      touch /mnt/snapshots/.writetest && rm -f /mnt/snapshots/.writetest \
        && ok "Проверка записи на NFS OK" \
        || warn "Нет записи на NFS — проверьте exports/права/firewall"
      end_stage_ok "NFS смонтирован"
    else
      end_stage_fail "mount NFS"
      return 1
    fi
  else
    info "Каталог /mnt/snapshots создан. Смонтируйте NFS позже перед path.repo"
    end_stage_skip "mount отложен"
  fi
}

print_final_report() {
  begin_stage "Итоговый отчёт"
  info "Роль ВМ: ${VM_ROLE}"
  info "ОС: ${OS_NAME} (${OS_FAMILY})"
  info "Успешных этапов: ${STAGE_OK}"
  info "Пропущенных: ${STAGE_SKIPPED}"
  info "С ошибками: ${STAGE_FAILED}"
  info "---- сводка ----"
  local s
  for s in "${STAGE_SUMMARY[@]}"; do
    info "${s}"
  done
  info "Отчёт: ${REPORT_FILE}"
  info "DEBUG: ${DEBUG_FILE}"
  info "Дальше: см. docs/wazuh-install.md (K8s / Wazuh) — этот скрипт их НЕ ставит"
  end_stage_ok "bootstrap хоста завершён"
  if [[ "${STAGE_FAILED}" -gt 0 ]]; then
    return 1
  fi
  return 0
}

bootstrap_init() {
  require_root "$@"
  _ensure_log_dir
  chmod 750 "${LOG_DIR}"
  touch "${REPORT_FILE}" "${DEBUG_FILE}"
  chmod 640 "${REPORT_FILE}" "${DEBUG_FILE}"
  set -e
  info "Старт bootstrap: $0 $*"
  info "ASSUME_YES=${ASSUME_YES} NONINTERACTIVE=${NONINTERACTIVE}"
}
