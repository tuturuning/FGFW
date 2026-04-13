#!/usr/bin/env bash

LOCAL_EXEC_MODE='false'

is_local_target() {
  local target_id="$1"
  [[ -n "${BIU_LOCAL_TARGET_ID:-}" && "${BIU_LOCAL_TARGET_ID}" == "${target_id}" ]]
}

run_target_sudo_script() {
  local script="$1"
  shift

  if [[ "${LOCAL_EXEC_MODE}" == 'true' ]]; then
    sudo bash -s -- "$@" <<<"${script}"
  else
    "${SSH_BASE_CMD[@]}" "${TARGET_DEST}" sudo bash -s -- "$@" <<<"${script}"
  fi
}

require_transport_dependencies() {
  local cmd
  for cmd in curl ruby tar; do
    command -v "${cmd}" >/dev/null 2>&1 || die "Missing required command: ${cmd}"
  done

  if [[ "${LOCAL_EXEC_MODE}" == 'true' ]]; then
    command -v sudo >/dev/null 2>&1 || die "Missing required command: sudo"
    return 0
  fi

  for cmd in ssh scp; do
    command -v "${cmd}" >/dev/null 2>&1 || die "Missing required command: ${cmd}"
  done
}

parse_target_args() {
  MANAGE_TARGET_ID="$(app_env_value DEFAULT_TARGET)"
  MANAGE_ALLOW_RESERVED='false'

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --target)
        [[ $# -ge 2 ]] || die "Missing value for --target"
        MANAGE_TARGET_ID="$2"
        shift 2
        ;;
      --allow-reserved-target)
        MANAGE_ALLOW_RESERVED='true'
        shift
        ;;
      *)
        break
        ;;
    esac
  done

  MANAGE_REMAINING_ARGS=("$@")
}

prepare_manage_target() {
  build_target_transport "${MANAGE_TARGET_ID}"
  require_transport_dependencies
}

service_action_script() {
  cat <<'REMOTE'
set -euo pipefail

action="$1"
shift

services=("$@")
for service in "${services[@]}"; do
  case "${action}" in
    start|stop|restart|enable|disable)
      systemctl "${action}" "${service}.service"
      ;;
    status)
      systemctl --no-pager --full status "${service}.service" || true
      ;;
    is-active)
      systemctl is-active "${service}.service" || true
      ;;
    *)
      echo "unsupported action: ${action}" >&2
      exit 1
      ;;
  esac
done
REMOTE
}

run_service_action() {
  local action="$1"
  shift
  parse_target_args "$@"
  prepare_manage_target
  local services=("${MANAGE_REMAINING_ARGS[@]}")
  [[ ${#services[@]} -gt 0 ]] || services=(xray sing-box)
  run_target_sudo_script "$(service_action_script)" "${action}" "${services[@]}"
}

run_install() {
  run_apply "$@"
}

run_restart() {
  run_service_action restart "$@"
}

run_upgrade() {
  run_apply "$@"
}

manual_backup_name() {
  date '+manual-%Y%m%d-%H%M%S'
}

run_backup() {
  ensure_runtime_dirs
  local snapshot_name snapshot_dir
  snapshot_name="$(manual_backup_name)"
  snapshot_dir="${BACKUP_DIR_DEFAULT}/${snapshot_name}"
  mkdir -p "${snapshot_dir}"

  cp -a "${CONFIG_DIR}" "${snapshot_dir}/config"
  mkdir -p "${snapshot_dir}/runtime"
  local entry
  for entry in bin config deploy logs output state; do
    [[ ! -e "${RUNTIME_DIR_DEFAULT}/${entry}" ]] || cp -a "${RUNTIME_DIR_DEFAULT}/${entry}" "${snapshot_dir}/runtime/${entry}"
  done
  if [[ -d "$(app_env_value CERT_DIR)" ]]; then
    cp -a "$(app_env_value CERT_DIR)" "${snapshot_dir}/runtime/certs"
  fi

  info "Backup created: ${snapshot_dir}"
}

latest_manual_backup() {
  find "${BACKUP_DIR_DEFAULT}" -maxdepth 1 -type d -name 'manual-*' | sort | tail -n 1
}

run_rollback() {
  ensure_runtime_dirs
  local snapshot_dir="${1:-}"
  if [[ -z "${snapshot_dir}" ]]; then
    snapshot_dir="$(latest_manual_backup)"
  fi
  [[ -n "${snapshot_dir}" && -d "${snapshot_dir}" ]] || die "No manual backup found"
  [[ -d "${snapshot_dir}/config" ]] || die "Backup missing config directory: ${snapshot_dir}"

  rm -rf "${CONFIG_DIR}"
  cp -a "${snapshot_dir}/config" "${CONFIG_DIR}"

  if [[ -d "${snapshot_dir}/runtime" ]]; then
    rm -rf "${RUNTIME_DIR_DEFAULT}"
    cp -a "${snapshot_dir}/runtime" "${RUNTIME_DIR_DEFAULT}"
  fi

  info "Rollback completed from ${snapshot_dir}"
}

uninstall_script() {
  cat <<'REMOTE'
set -euo pipefail

runtime_dir="$1"
cert_dir="$2"
mode="$3"

remove_service() {
  local service="$1"
  systemctl stop "${service}.service" >/dev/null 2>&1 || true
  systemctl disable "${service}.service" >/dev/null 2>&1 || true
  rm -f "/etc/systemd/system/${service}.service"
}

case "${mode}" in
  xray)
    remove_service xray
    rm -f "${runtime_dir}/bin/xray"
    rm -f "${runtime_dir}/config/xray.json"
    ;;
  sing-box)
    remove_service sing-box
    rm -f "${runtime_dir}/bin/sing-box"
    rm -f "${runtime_dir}/config/sing-box.json"
    ;;
  cloudflared)
    remove_service cloudflared
    rm -f "${runtime_dir}/bin/cloudflared"
    ;;
  generated)
    rm -rf "${runtime_dir}/config" "${runtime_dir}/output" "${runtime_dir}/deploy"
    rm -f /usr/local/bin/biu /usr/bin/biu
    ;;
  all)
    remove_service xray
    remove_service sing-box
    remove_service cloudflared
    rm -rf "${runtime_dir}/bin" "${runtime_dir}/config" "${runtime_dir}/output" "${runtime_dir}/deploy" "${runtime_dir}/state" "${runtime_dir}/logs"
    rm -f /usr/local/bin/biu /usr/bin/biu
    ;;
  all-and-certs)
    remove_service xray
    remove_service sing-box
    remove_service cloudflared
    rm -rf "${runtime_dir}/bin" "${runtime_dir}/config" "${runtime_dir}/output" "${runtime_dir}/deploy" "${runtime_dir}/state" "${runtime_dir}/logs" "${cert_dir}"
    rm -f /usr/local/bin/biu /usr/bin/biu
    ;;
  *)
    echo "Unknown uninstall mode: ${mode}" >&2
    exit 1
    ;;
esac

systemctl daemon-reload
REMOTE
}

run_uninstall() {
  local mode="${1:-all}"
  shift || true
  parse_target_args "$@"
  prepare_manage_target

  if [[ "${TARGET_ROLE}" == "reserved-host" && "${MANAGE_ALLOW_RESERVED}" != 'true' ]]; then
    die "Refuse uninstall on reserved-host ${MANAGE_TARGET_ID} without --allow-reserved-target"
  fi

  run_target_sudo_script "$(uninstall_script)" "$(app_env_value RUNTIME_DIR)" "$(app_env_value CERT_DIR)" "${mode}"
  info "Uninstall completed: ${mode} on ${MANAGE_TARGET_ID}"
}

remote_snapshot_rollback_script() {
  cat <<'REMOTE'
set -euo pipefail

runtime_dir="$1"
cert_dir="$2"

backup_root="${runtime_dir}/backups"
latest_backup="$(find "${backup_root}" -maxdepth 1 -type d -name 'apply-*' | sort | tail -n 1)"
[[ -n "${latest_backup}" && -d "${latest_backup}" ]] || { echo "No apply backup found" >&2; exit 1; }

restore_dir() {
  local src="$1"
  local dst="$2"
  if [[ -d "${src}" ]]; then
    rm -rf "${dst}"
    cp -a "${src}" "${dst}"
  fi
}

restore_file() {
  local src="$1"
  local dst="$2"
  if [[ -f "${src}" ]]; then
    install -m 0644 "${src}" "${dst}"
  fi
}

restore_dir "${latest_backup}/bin" "${runtime_dir}/bin"
restore_dir "${latest_backup}/config" "${runtime_dir}/config"
restore_dir "${latest_backup}/output" "${runtime_dir}/output"
restore_dir "${latest_backup}/deploy" "${runtime_dir}/deploy"
restore_dir "${latest_backup}/certs" "${cert_dir}"

if [[ -f "${latest_backup}/biu.local" ]]; then
  install -m 0755 "${latest_backup}/biu.local" /usr/local/bin/biu
  ln -sfn /usr/local/bin/biu /usr/bin/biu
fi

restore_file "${latest_backup}/xray.service" /etc/systemd/system/xray.service
restore_file "${latest_backup}/sing-box.service" /etc/systemd/system/sing-box.service

systemctl daemon-reload
systemctl try-restart xray.service >/dev/null 2>&1 || true
systemctl try-restart sing-box.service >/dev/null 2>&1 || true
echo "${latest_backup}"
REMOTE
}

run_remote_snapshot_rollback() {
  parse_target_args "$@"
  prepare_manage_target

  if [[ "${TARGET_ROLE}" == "reserved-host" && "${MANAGE_ALLOW_RESERVED}" != 'true' ]]; then
    die "Refuse rollback on reserved-host ${MANAGE_TARGET_ID} without --allow-reserved-target"
  fi

  local restored
  restored="$(run_target_sudo_script "$(remote_snapshot_rollback_script)" "$(app_env_value RUNTIME_DIR)" "$(app_env_value CERT_DIR)")"
  info "Remote apply snapshot restored: ${restored}"
}
