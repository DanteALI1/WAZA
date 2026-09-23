#!/usr/bin/env bash
# Автотесты bootstrap-библиотеки (без порчи хоста).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LIB="${ROOT}/scripts/bootstrap/lib/common.sh"

PASS=0
FAIL=0
assert_eq() {
  local name="$1" got="$2" want="$3"
  if [[ "${got}" == "${want}" ]]; then
    echo "PASS: ${name}"
    PASS=$((PASS + 1))
  else
    echo "FAIL: ${name} (got='${got}' want='${want}')"
    FAIL=$((FAIL + 1))
  fi
}
assert_true() {
  local name="$1"; shift
  if "$@"; then
    echo "PASS: ${name}"
    PASS=$((PASS + 1))
  else
    echo "FAIL: ${name}"
    FAIL=$((FAIL + 1))
  fi
}
assert_false() {
  local name="$1"; shift
  if "$@"; then
    echo "FAIL: ${name} (expected false)"
    FAIL=$((FAIL + 1))
  else
    echo "PASS: ${name}"
    PASS=$((PASS + 1))
  fi
}

TMP="$(mktemp -d)"
export LOG_DIR="${TMP}/logs"
export REPORT_FILE="${LOG_DIR}/report.txt"
export DEBUG_FILE="${LOG_DIR}/debug.log"
mkdir -p "${LOG_DIR}"

# shellcheck source=/dev/null
source "${LIB}"

echo "=== 1. logging / stages ==="
info "test-info"
ok "test-ok"
warn "test-warn"
debug "test-debug"
begin_stage "unit-stage"
end_stage_ok "detail-ok"
assert_true "report exists" test -f "${REPORT_FILE}"
assert_true "debug exists" test -f "${DEBUG_FILE}"
assert_true "report contains OK" grep -q "test-ok" "${REPORT_FILE}"
assert_eq "STAGE_OK count" "${STAGE_OK}" "1"

echo "=== 2. run_cmd success / fail debug ==="
assert_true "run_cmd true" run_cmd "true-cmd" true
set +e
run_cmd "false-cmd" false
rc=$?
set -e
assert_eq "run_cmd false rc" "${rc}" "1"
assert_true "debug has FAIL" grep -q "FAIL" "${DEBUG_FILE}"

echo "=== 3. ask_yes_no noninteractive ==="
NONINTERACTIVE=1
ASSUME_YES=0
assert_true "default y => yes" ask_yes_no "q" "y"
assert_false "default n => no" ask_yes_no "q" "n"
ASSUME_YES=1
assert_true "ASSUME_YES forces yes" ask_yes_no "q" "n"
ASSUME_YES=0
NONINTERACTIVE=0

echo "=== 4. detect_os on current host ==="
VM_ROLE="test"
detect_os
assert_true "OS_FAMILY set" test -n "${OS_FAMILY}"
echo "    detected OS_FAMILY=${OS_FAMILY} OS_ID=${OS_ID}"
# Ubuntu agent => debian family
if [[ -f /etc/os-release ]] && grep -qi ubuntu /etc/os-release; then
  assert_eq "ubuntu => debian family" "${OS_FAMILY}" "debian"
fi

echo "=== 5. print_system_facts ==="
assert_true "print_system_facts" print_system_facts

echo "=== 6. scripts --help exit 0 ==="
for s in \
  bootstrap-k8s-indexer.sh \
  bootstrap-k8s-manager.sh \
  bootstrap-k8s-dashboard.sh \
  bootstrap-wazuh-archive.sh
do
  set +e
  bash "${ROOT}/scripts/bootstrap/${s}" --help >/dev/null
  rc=$?
  set -e
  assert_eq "${s} --help rc" "${rc}" "0"
done

echo "=== 7. non-root must exit 1 ==="
set +e
bash "${ROOT}/scripts/bootstrap/bootstrap-k8s-dashboard.sh" -n >/tmp/bs-out.txt 2>/tmp/bs-err.txt
rc=$?
set -e
assert_eq "non-root exit" "${rc}" "1"
assert_true "non-root message" grep -qi "root" /tmp/bs-err.txt

echo "=== 8. bash -n all scripts ==="
for f in "${ROOT}/scripts/bootstrap/lib/common.sh" "${ROOT}/scripts/bootstrap"/bootstrap-*.sh; do
  assert_true "bash -n $(basename "$f")" bash -n "$f"
done

echo "=== 9. role scripts wire expected stages ==="
assert_true "indexer: create_access_model" grep -q create_access_model "${ROOT}/scripts/bootstrap/bootstrap-k8s-indexer.sh"
assert_true "manager: create_access_model" grep -q create_access_model "${ROOT}/scripts/bootstrap/bootstrap-k8s-manager.sh"
assert_true "dashboard: create_access_model" grep -q create_access_model "${ROOT}/scripts/bootstrap/bootstrap-k8s-dashboard.sh"
assert_true "archive: NFS server" grep -q install_nfs_server_archive "${ROOT}/scripts/bootstrap/bootstrap-wazuh-archive.sh"
assert_true "indexer: NFS client" grep -q prepare_nfs_client_mount "${ROOT}/scripts/bootstrap/bootstrap-k8s-indexer.sh"
assert_true "indexer: data disk" grep -q prepare_data_disk "${ROOT}/scripts/bootstrap/bootstrap-k8s-indexer.sh"
assert_true "manager: data disk" grep -q prepare_data_disk "${ROOT}/scripts/bootstrap/bootstrap-k8s-manager.sh"
assert_true "dashboard: no data disk call with mount" grep -vq 'prepare_data_disk "' "${ROOT}/scripts/bootstrap/bootstrap-k8s-dashboard.sh" || true
# dashboard must NOT call prepare_data_disk
if grep -q prepare_data_disk "${ROOT}/scripts/bootstrap/bootstrap-k8s-dashboard.sh"; then
  echo "FAIL: dashboard should not call prepare_data_disk"
  FAIL=$((FAIL + 1))
else
  echo "PASS: dashboard has no prepare_data_disk"
  PASS=$((PASS + 1))
fi

echo
echo "==== RESULT: PASS=${PASS} FAIL=${FAIL} ===="
echo "Logs under ${TMP}"
[[ "${FAIL}" -eq 0 ]]
