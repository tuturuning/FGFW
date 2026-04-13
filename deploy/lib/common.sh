#!/usr/bin/env bash

CONFIG_DIR="${BIU_CONFIG_DIR:-${SCRIPT_DIR}/config}"
RUNTIME_DIR_DEFAULT="${BIU_RUNTIME_DIR:-${PROJECT_ROOT}/runtime}"
RUNTIME_CONFIG_DIR_DEFAULT="${BIU_RUNTIME_CONFIG_DIR:-${RUNTIME_DIR_DEFAULT}/config}"
OUTPUT_DIR_DEFAULT="${BIU_OUTPUT_DIR:-${RUNTIME_DIR_DEFAULT}/output}"
BACKUP_DIR_DEFAULT="${BIU_BACKUP_DIR:-${RUNTIME_DIR_DEFAULT}/backups}"
LOG_DIR_DEFAULT="${BIU_LOG_DIR:-${RUNTIME_DIR_DEFAULT}/logs}"
STATE_DIR_DEFAULT="${BIU_STATE_DIR:-${RUNTIME_DIR_DEFAULT}/state}"
RUNTIME_SYSTEMD_DIR_DEFAULT="${BIU_RUNTIME_SYSTEMD_DIR:-${RUNTIME_CONFIG_DIR_DEFAULT}/systemd}"

info() {
  printf '[INFO] %s\n' "$*"
}

warn() {
  printf '[WARN] %s\n' "$*" >&2
}

die() {
  printf '[ERROR] %s\n' "$*" >&2
  exit 1
}

require_file() {
  local path="$1"
  [[ -f "${path}" ]] || die "Required file not found: ${path}"
}

print_kv() {
  printf '%-20s %s\n' "$1" "$2"
}

ensure_runtime_dirs() {
  mkdir -p \
    "${RUNTIME_DIR_DEFAULT}" \
    "${RUNTIME_CONFIG_DIR_DEFAULT}" \
    "${RUNTIME_SYSTEMD_DIR_DEFAULT}" \
    "${OUTPUT_DIR_DEFAULT}" \
    "${BACKUP_DIR_DEFAULT}" \
    "${LOG_DIR_DEFAULT}" \
    "${STATE_DIR_DEFAULT}"
}

resolve_secrets_file() {
  if [[ -f "${CONFIG_DIR}/secrets.env" ]]; then
    printf '%s\n' "${CONFIG_DIR}/secrets.env"
  else
    printf '%s\n' "${CONFIG_DIR}/secrets.env.example"
  fi
}
