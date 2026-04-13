#!/usr/bin/env bash

app_env_value() {
  local key="$1"
  local file="${CONFIG_DIR}/app.env.example"
  awk -F= -v key="${key}" '$1 == key { print substr($0, index($0, "=") + 1); exit }' "${file}"
}

secret_env_value() {
  local key="$1"
  local file
  file="$(resolve_secrets_file)"
  awk -F= -v key="${key}" '$1 == key { print substr($0, index($0, "=") + 1); exit }' "${file}"
}

target_field() {
  local target_id="$1"
  local field="$2"
  ruby - "${CONFIG_DIR}/targets.yaml" "${target_id}" "${field}" <<'RUBY'
require "yaml"

file = ARGV[0]
target_id = ARGV[1]
field = ARGV[2]
target = Array((YAML.load_file(file) || {})["targets"]).find { |item| item["id"] == target_id }
abort "target not found: #{target_id}" unless target

value = target[field]
puts value.nil? ? "" : value
RUBY
}

require_apply_dependencies() {
  require_transport_dependencies
}

ensure_real_secrets() {
  local secrets_file
  secrets_file="$(resolve_secrets_file)"

  [[ "${secrets_file}" != "${CONFIG_DIR}/secrets.env.example" ]] || \
    die "apply 已拒绝：当前仍在使用 secrets.env.example，请先创建 deploy/config/secrets.env"
}

parse_apply_args() {
  APPLY_TARGET_ID="$(app_env_value DEFAULT_TARGET)"
  APPLY_ALLOW_RESERVED='false'
  APPLY_SKIP_START='false'

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --target)
        [[ $# -ge 2 ]] || die "Missing value for --target"
        APPLY_TARGET_ID="$2"
        shift 2
        ;;
      --allow-reserved-target)
        APPLY_ALLOW_RESERVED='true'
        shift
        ;;
      --skip-start)
        APPLY_SKIP_START='true'
        shift
        ;;
      *)
        die "Unknown apply option: $1"
        ;;
    esac
  done
}

resolve_release_tag() {
  local repo="$1"
  local spec="$2"

  if [[ "${spec}" == "latest" ]]; then
    curl -fsSL "https://api.github.com/repos/${repo}/releases/latest" | \
      ruby -rjson -e 'data = JSON.parse(STDIN.read); puts data.fetch("tag_name")'
    return
  fi

  if [[ "${spec}" =~ \.x$ ]]; then
    curl -fsSL "https://api.github.com/repos/${repo}/releases?per_page=100" | \
      ruby -rjson -e '
        spec = ARGV[0]
        prefix = spec.sub(/\Av/, "").sub(/\.x\z/, ".")
        data = JSON.parse(STDIN.read)
        match = data.find do |release|
          tag = release["tag_name"].to_s.sub(/\Av/, "")
          !release["prerelease"] && !release["draft"] && tag.start_with?(prefix)
        end
        abort "no release matched #{spec}" unless match
        puts match.fetch("tag_name")
      ' "${spec}"
    return
  fi

  if [[ "${spec}" == v* ]]; then
    printf '%s\n' "${spec}"
  else
    printf 'v%s\n' "${spec}"
  fi
}

xray_asset_name_for_arch() {
  case "$1" in
    x86_64|amd64)
      printf 'Xray-linux-64.zip\n'
      ;;
    aarch64|arm64)
      printf 'Xray-linux-arm64-v8a.zip\n'
      ;;
    *)
      die "Unsupported Xray architecture: $1"
      ;;
  esac
}

singbox_asset_name_for_arch() {
  local version="$1"
  local arch="$2"
  case "${arch}" in
    x86_64|amd64)
      printf 'sing-box-%s-linux-amd64.tar.gz\n' "${version}"
      ;;
    aarch64|arm64)
      printf 'sing-box-%s-linux-arm64.tar.gz\n' "${version}"
      ;;
    *)
      die "Unsupported sing-box architecture: ${arch}"
      ;;
  esac
}

build_target_transport() {
  local target_id="$1"
  TARGET_SSH_HOST="$(target_field "${target_id}" ssh_host)"
  TARGET_SSH_USER="$(target_field "${target_id}" ssh_user)"
  TARGET_SSH_AUTH="$(target_field "${target_id}" ssh_auth)"
  TARGET_SSH_KEY_PATH="$(target_field "${target_id}" ssh_key_path)"
  TARGET_SSH_PASSWORD_REF="$(target_field "${target_id}" ssh_password_ref)"
  TARGET_ROLE="$(target_field "${target_id}" role)"
  TARGET_NAME="$(target_field "${target_id}" name)"
  TARGET_DEST="${TARGET_SSH_USER}@${TARGET_SSH_HOST}"
  LOCAL_EXEC_MODE='false'

  if is_local_target "${target_id}"; then
    LOCAL_EXEC_MODE='true'
    SSH_BASE_CMD=()
    SCP_BASE_CMD=()
    return 0
  fi

  SSH_BASE_CMD=(
    ssh
    -o StrictHostKeyChecking=no
    -o UserKnownHostsFile=/dev/null
    -o LogLevel=ERROR
  )
  SCP_BASE_CMD=(
    scp
    -o StrictHostKeyChecking=no
    -o UserKnownHostsFile=/dev/null
    -o LogLevel=ERROR
  )

  case "${TARGET_SSH_AUTH}" in
    key)
      [[ -n "${TARGET_SSH_KEY_PATH}" ]] || die "Target ${target_id} is missing ssh_key_path"
      SSH_BASE_CMD+=(-i "${TARGET_SSH_KEY_PATH}")
      SCP_BASE_CMD+=(-i "${TARGET_SSH_KEY_PATH}")
      ;;
    password)
      command -v sshpass >/dev/null 2>&1 || die "Password target requires local sshpass: ${target_id}"
      local ssh_password
      ssh_password="$(secret_env_value "${TARGET_SSH_PASSWORD_REF}")"
      [[ -n "${ssh_password}" ]] || die "Missing password secret for ${TARGET_SSH_PASSWORD_REF}"
      SSH_BASE_CMD=(sshpass -p "${ssh_password}" "${SSH_BASE_CMD[@]}")
      SCP_BASE_CMD=(sshpass -p "${ssh_password}" "${SCP_BASE_CMD[@]}")
      ;;
    *)
      die "Unsupported ssh_auth '${TARGET_SSH_AUTH}' for target ${target_id}"
      ;;
  esac

  if [[ "${TARGET_ROLE}" == "reserved-host" && "${APPLY_ALLOW_RESERVED}" != 'true' ]]; then
    die "Target ${target_id} is reserved-host。当前 apply 默认只允许部署到 clean-host；如确需继续，请显式传 --allow-reserved-target"
  fi
}

remote_exec() {
  if [[ "${LOCAL_EXEC_MODE}" == 'true' ]]; then
    if [[ $# -eq 1 ]]; then
      bash -lc "$1"
    else
      "$@"
    fi
  else
    "${SSH_BASE_CMD[@]}" "${TARGET_DEST}" "$@"
  fi
}

collect_required_ports() {
  ruby - "${OUTPUT_DIR_DEFAULT}/manifest.json" "${APPLY_TARGET_ID}" <<'RUBY'
require "json"

manifest = JSON.parse(File.read(ARGV[0]))
target_id = ARGV[1]

Array(manifest["nodes"]).each do |node|
  next unless node["enabled"] && node["target"] == target_id

  port_value = node.dig("listen", "port")
  next unless port_value
  ports =
    case port_value
    when Integer
      [port_value]
    when String
      if port_value.include?("-")
        start_port, end_port = port_value.split("-", 2).map(&:to_i)
        (start_port..end_port).to_a
      else
        [port_value.to_i]
      end
    else
      []
    end

  transports =
    case [node["protocol"], node["transport"]]
    when ["hysteria2", "quic"], ["tuic", "quic"]
      ["udp"]
    when ["ss2022", "tcpudp"]
      ["tcp", "udp"]
    else
      ["tcp"]
    end

  transports.each do |transport|
    ports.each do |port|
      puts "#{transport}:#{port}:#{node["id"]}"
    end
  end
end
RUBY
}

collect_required_cert_paths() {
  ruby - "${OUTPUT_DIR_DEFAULT}/manifest.json" "${APPLY_TARGET_ID}" <<'RUBY'
require "json"

manifest = JSON.parse(File.read(ARGV[0]))
target_id = ARGV[1]

Array(manifest["nodes"]).each do |node|
  next unless node["enabled"] && node["target"] == target_id
  mode = node.dig("tls", "cert_mode")
  cert = node.dig("tls", "cert_ref", "fullchain")
  key = node.dig("tls", "cert_ref", "privkey")
  next if cert.nil? && key.nil?

  puts [node["id"], mode, cert, key].join("\t")
end
RUBY
}

collect_acme_requests() {
  local acme_plan="${OUTPUT_DIR_DEFAULT}/acme-plan.json"
  [[ -f "${acme_plan}" ]] || return 0

  ruby - "${acme_plan}" "${APPLY_TARGET_ID}" <<'RUBY'
require "json"

plan = JSON.parse(File.read(ARGV[0]))
target_id = ARGV[1]

Array(plan).each do |item|
  next unless item["target"] == target_id

  puts [
    item["node_id"],
    item["challenge"],
    item["standalone_port"],
    item["main_domain"],
    item["cert_path"],
    item["key_path"]
  ].join("\t")
end
RUBY
}

assert_remote_port_available() {
  local proto="$1"
  local port="$2"
  local node_id="$3"
  local check_cmd

  case "${proto}" in
    tcp)
      check_cmd=$(cat <<EOF
output=\$(sudo ss -H -ltnp "( sport = :${port} )" 2>/dev/null || true)
if [[ -z "\${output}" ]]; then
  exit 1
fi
filtered=\$(printf '%s\n' "\${output}" | grep -Ev 'xray|sing-box|systemd' || true)
[[ -n "\${filtered}" ]]
EOF
)
      ;;
    udp)
      check_cmd=$(cat <<EOF
output=\$(sudo ss -H -lunp "( sport = :${port} )" 2>/dev/null || true)
if [[ -z "\${output}" ]]; then
  exit 1
fi
filtered=\$(printf '%s\n' "\${output}" | grep -Ev 'xray|sing-box|systemd' || true)
[[ -n "\${filtered}" ]]
EOF
)
      ;;
    *)
      die "Unknown protocol for port check: ${proto}"
      ;;
  esac

  if remote_exec "bash -lc $(printf '%q' "${check_cmd}")" >/dev/null 2>&1; then
    die "Target ${APPLY_TARGET_ID} port conflict: ${proto}/${port} is already in use, node=${node_id}"
  fi
}

assert_remote_cert_paths() {
  local line node_id cert_mode cert_path key_path
  while IFS=$'\t' read -r node_id cert_mode cert_path key_path; do
    [[ -n "${node_id}" ]] || continue
    if [[ "${cert_mode}" == "acme" ]]; then
      continue
    fi
    if [[ -n "${cert_path}" ]] && ! remote_exec "test -f $(printf '%q' "${cert_path}")"; then
      die "Target ${APPLY_TARGET_ID} 缺少证书文件: ${cert_path} (node ${node_id})"
    fi
    if [[ -n "${key_path}" ]] && ! remote_exec "test -f $(printf '%q' "${key_path}")"; then
      die "Target ${APPLY_TARGET_ID} 缺少私钥文件: ${key_path} (node ${node_id})"
    fi
  done < <(collect_required_cert_paths)
}

assert_remote_acme_preflight() {
  local line node_id challenge port main_domain cert_path key_path
  local seen=""

  while IFS=$'\t' read -r node_id challenge port main_domain cert_path key_path; do
    [[ -n "${node_id}" ]] || continue
    if [[ "${challenge}" == "standalone" ]]; then
      if [[ " ${seen} " != *" tcp:${port} "* ]]; then
        assert_remote_port_available "tcp" "${port}" "acme:${node_id}"
        seen="${seen} tcp:${port}"
      fi
    fi
  done < <(collect_acme_requests)
}

prepare_apply_release() {
  APPLY_RUNTIME_DIR="$(app_env_value RUNTIME_DIR)"
  APPLY_XRAY_VERSION_SPEC="$(app_env_value XRAY_VERSION)"
  APPLY_SINGBOX_VERSION_SPEC="$(app_env_value SINGBOX_VERSION)"
  APPLY_RELEASE_ID="$(date '+%Y%m%d-%H%M%S')"
  APPLY_REMOTE_PACKAGE="/tmp/myproxy-apply-${APPLY_RELEASE_ID}.tar"

  APPLY_XRAY_TAG="$(resolve_release_tag 'XTLS/Xray-core' "${APPLY_XRAY_VERSION_SPEC}")"
  APPLY_SINGBOX_TAG="$(resolve_release_tag 'SagerNet/sing-box' "${APPLY_SINGBOX_VERSION_SPEC}")"
}

package_runtime_payload() {
  APPLY_LOCAL_PACKAGE="$(mktemp "${TMPDIR:-/tmp}/myproxy-apply.XXXXXX.tar")"
  COPYFILE_DISABLE=1 COPY_EXTENDED_ATTRIBUTES_DISABLE=1 tar \
    -C "${RUNTIME_DIR_DEFAULT}" -cf "${APPLY_LOCAL_PACKAGE}" config output \
    -C "${PROJECT_ROOT}" deploy
}

cleanup_apply_package() {
  if [[ -n "${APPLY_LOCAL_PACKAGE:-}" && -f "${APPLY_LOCAL_PACKAGE}" ]]; then
    rm -f "${APPLY_LOCAL_PACKAGE}"
  fi
}

remote_detect_arch() {
  APPLY_REMOTE_ARCH="$(remote_exec "uname -m" | tr -d '\r')"
  [[ -n "${APPLY_REMOTE_ARCH}" ]] || die "Failed to detect remote architecture"
}

remote_preflight_checks() {
  local line proto port node_id

  info "Running remote preflight on ${APPLY_TARGET_ID} (${TARGET_NAME})..."
  while IFS=: read -r proto port node_id; do
    [[ -n "${proto}" ]] || continue
    assert_remote_port_available "${proto}" "${port}" "${node_id}"
  done < <(collect_required_ports)

  assert_remote_acme_preflight
  assert_remote_cert_paths
}

upload_runtime_payload() {
  if [[ "${LOCAL_EXEC_MODE}" == 'true' ]]; then
    info "Using local runtime payload on ${APPLY_TARGET_ID}..."
    APPLY_REMOTE_PACKAGE="${APPLY_LOCAL_PACKAGE}"
    return 0
  fi
  info "Uploading rendered runtime payload to ${APPLY_TARGET_ID}..."
  "${SCP_BASE_CMD[@]}" "${APPLY_LOCAL_PACKAGE}" "${TARGET_DEST}:${APPLY_REMOTE_PACKAGE}"
}

remote_apply_release() {
  local xray_asset singbox_asset singbox_version xray_url singbox_url cert_dir

  xray_asset="$(xray_asset_name_for_arch "${APPLY_REMOTE_ARCH}")"
  singbox_version="${APPLY_SINGBOX_TAG#v}"
  singbox_asset="$(singbox_asset_name_for_arch "${singbox_version}" "${APPLY_REMOTE_ARCH}")"
  cert_dir="$(app_env_value CERT_DIR)"

  xray_url="https://github.com/XTLS/Xray-core/releases/download/${APPLY_XRAY_TAG}/${xray_asset}"
  singbox_url="https://github.com/SagerNet/sing-box/releases/download/${APPLY_SINGBOX_TAG}/${singbox_asset}"

  info "Applying release ${APPLY_RELEASE_ID} to ${APPLY_TARGET_ID}..."
  run_target_sudo_script "$(cat <<'REMOTE'
set -euo pipefail

runtime_dir="$1"
remote_package="$2"
release_id="$3"
xray_url="$4"
singbox_url="$5"
skip_start="$6"
xray_tag="$7"
singbox_tag="$8"
target_id="$9"
cert_dir="${10}"

bin_dir="${runtime_dir}/bin"
config_dir="${runtime_dir}/config"
output_dir="${runtime_dir}/output"
deploy_dir="${runtime_dir}/deploy"
backup_root="${runtime_dir}/backups"
state_dir="${runtime_dir}/state"
logs_dir="${runtime_dir}/logs"
backup_dir="${backup_root}/apply-${release_id}"
tmp_dir="$(mktemp -d)"
rollback_ready=0

cleanup() {
  rm -rf "${tmp_dir}"
  rm -f "${remote_package}"
}

rollback() {
  if [[ "${rollback_ready}" -eq 1 ]]; then
    if [[ -d "${backup_dir}/bin" ]]; then
      rm -rf "${bin_dir}"
      cp -a "${backup_dir}/bin" "${bin_dir}"
    fi
    if [[ -d "${backup_dir}/config" ]]; then
      rm -rf "${config_dir}"
      cp -a "${backup_dir}/config" "${config_dir}"
    fi
    if [[ -d "${backup_dir}/output" ]]; then
      rm -rf "${output_dir}"
      cp -a "${backup_dir}/output" "${output_dir}"
    fi
    if [[ -d "${backup_dir}/deploy" ]]; then
      rm -rf "${deploy_dir}"
      cp -a "${backup_dir}/deploy" "${deploy_dir}"
    else
      rm -rf "${deploy_dir}"
    fi
    if [[ -d "${backup_dir}/certs" ]]; then
      rm -rf "${cert_dir}"
      cp -a "${backup_dir}/certs" "${cert_dir}"
    fi
    if [[ -f "${backup_dir}/biu.local" ]]; then
      install -m 0755 "${backup_dir}/biu.local" /usr/local/bin/biu
    else
      rm -f /usr/local/bin/biu
    fi
    if [[ -f "${backup_dir}/biu.bin" ]]; then
      install -m 0755 "${backup_dir}/biu.bin" /usr/bin/biu
    else
      rm -f /usr/bin/biu
    fi
    if [[ -f "${backup_dir}/xray.service" ]]; then
      install -m 0644 "${backup_dir}/xray.service" /etc/systemd/system/xray.service
    fi
    if [[ -f "${backup_dir}/sing-box.service" ]]; then
      install -m 0644 "${backup_dir}/sing-box.service" /etc/systemd/system/sing-box.service
    fi
    systemctl daemon-reload || true
    systemctl try-restart xray.service || true
    systemctl try-restart sing-box.service || true
  fi
  cleanup
}

trap 'rollback' ERR
trap 'cleanup' EXIT

apt-get update
apt-get install -y ca-certificates curl unzip tar socat python3 ruby ripgrep

mkdir -p "${bin_dir}" "${backup_root}" "${state_dir}" "${logs_dir}" "${cert_dir}"
if [[ -d "${bin_dir}" || -d "${config_dir}" || -d "${output_dir}" || -d "${deploy_dir}" || -d "${cert_dir}" || -f /usr/local/bin/biu || -f /usr/bin/biu || -f /etc/systemd/system/xray.service || -f /etc/systemd/system/sing-box.service ]]; then
  mkdir -p "${backup_dir}"
  [[ ! -d "${bin_dir}" ]] || cp -a "${bin_dir}" "${backup_dir}/bin"
  [[ ! -d "${config_dir}" ]] || cp -a "${config_dir}" "${backup_dir}/config"
  [[ ! -d "${output_dir}" ]] || cp -a "${output_dir}" "${backup_dir}/output"
  [[ ! -d "${deploy_dir}" ]] || cp -a "${deploy_dir}" "${backup_dir}/deploy"
  [[ ! -d "${cert_dir}" ]] || cp -a "${cert_dir}" "${backup_dir}/certs"
  [[ ! -f /usr/local/bin/biu ]] || cp -a /usr/local/bin/biu "${backup_dir}/biu.local"
  [[ ! -f /usr/bin/biu ]] || cp -a /usr/bin/biu "${backup_dir}/biu.bin"
  [[ ! -f /etc/systemd/system/xray.service ]] || cp -a /etc/systemd/system/xray.service "${backup_dir}/xray.service"
  [[ ! -f /etc/systemd/system/sing-box.service ]] || cp -a /etc/systemd/system/sing-box.service "${backup_dir}/sing-box.service"
  rollback_ready=1
fi

curl -fsSL "${xray_url}" -o "${tmp_dir}/xray.zip"
curl -fsSL "${singbox_url}" -o "${tmp_dir}/sing-box.tar.gz"
unzip -oq "${tmp_dir}/xray.zip" -d "${tmp_dir}/xray"
tar -xzf "${tmp_dir}/sing-box.tar.gz" -C "${tmp_dir}"

install -m 0755 "${tmp_dir}/xray/xray" "${bin_dir}/xray"
find "${tmp_dir}" -type f -path '*/sing-box' -print -quit | while read -r path; do
  install -m 0755 "${path}" "${bin_dir}/sing-box"
done
[[ -x "${bin_dir}/sing-box" ]] || { echo "sing-box binary not found after extraction" >&2; exit 1; }

mkdir -p "${runtime_dir}"
tar -xf "${remote_package}" -C "${runtime_dir}"
chmod 0755 "${deploy_dir}/install.sh"
find "${deploy_dir}/lib" -type f -name '*.sh' -exec chmod 0755 {} \;
find "${deploy_dir}" -type d -exec chmod 0755 {} \;
if [[ -f "${deploy_dir}/config/secrets.env" ]]; then
  chmod 0600 "${deploy_dir}/config/secrets.env"
fi

cat > "${bin_dir}/reload-certs.sh" <<'HOOK'
#!/usr/bin/env bash
set -euo pipefail
systemctl try-restart xray.service >/dev/null 2>&1 || true
systemctl try-restart sing-box.service >/dev/null 2>&1 || true
HOOK
chmod 0755 "${bin_dir}/reload-certs.sh"

cat > /usr/local/bin/biu <<EOF
#!/usr/bin/env bash
set -euo pipefail

if [[ "\${EUID}" -ne 0 ]]; then
  exec sudo -E /usr/local/bin/biu "\$@"
fi

export BIU_CONFIG_DIR="${deploy_dir}/config"
export BIU_RUNTIME_DIR="${runtime_dir}"
export BIU_RUNTIME_CONFIG_DIR="${config_dir}"
export BIU_OUTPUT_DIR="${output_dir}"
export BIU_BACKUP_DIR="${backup_root}"
export BIU_LOG_DIR="${logs_dir}"
export BIU_STATE_DIR="${state_dir}"
export BIU_RUNTIME_SYSTEMD_DIR="${config_dir}/systemd"
export BIU_LOCAL_TARGET_ID="${target_id}"

if [[ \$# -eq 0 ]]; then
  set -- menu
fi

exec "${deploy_dir}/install.sh" "\$@"
EOF
chmod 0755 /usr/local/bin/biu
ln -sfn /usr/local/bin/biu /usr/bin/biu

python3 - "${output_dir}/acme-plan.json" "${target_id}" "${bin_dir}/reload-certs.sh" <<'PY'
import json
import os
import shlex
import subprocess
import sys

plan_path = sys.argv[1]
target_id = sys.argv[2]
reload_hook = sys.argv[3]

if not os.path.exists(plan_path):
    sys.exit(0)

with open(plan_path, "r", encoding="utf-8") as fh:
    requests = [item for item in json.load(fh) if item.get("target") == target_id]

if not requests:
    sys.exit(0)

first = requests[0]
install_dir = first.get("install_dir") or "/root/.acme.sh"
acme_bin = os.path.join(install_dir, "acme.sh")
email = first.get("email") or ""

env = os.environ.copy()
if not os.path.exists(acme_bin):
    install_cmd = "curl -fsSL https://get.acme.sh | sh -s email=" + shlex.quote(email)
    subprocess.run(["bash", "-lc", install_cmd], check=True, env=env)

for request in requests:
    request_env = env.copy()
    for key, value in (request.get("dns_env") or {}).items():
        request_env[str(key)] = str(value)

    server = request.get("server") or "letsencrypt"
    subprocess.run([acme_bin, "--set-default-ca", "--server", server], check=True, env=request_env)

    domains = request.get("domains") or []
    if not domains:
        raise SystemExit(f"ACME request has no domains: {request}")

    issue_cmd = [acme_bin, "--issue"]
    challenge = request.get("challenge") or "standalone"
    if challenge == "dns":
        dns_provider = request.get("dns_provider")
        if not dns_provider:
            raise SystemExit(f"dns challenge requires dns_provider: {request}")
        issue_cmd.extend(["--dns", dns_provider])
    else:
        issue_cmd.extend(["--standalone", "--httpport", str(request.get("standalone_port") or 80)])

    issue_cmd.extend(["--server", server, "--keylength", request.get("key_type") or "ec-256"])
    for domain in domains:
        issue_cmd.extend(["-d", domain])
    issue_result = subprocess.run(issue_cmd, env=request_env)
    if issue_result.returncode not in (0, 2):
        raise SystemExit(issue_result.returncode)

    cert_path = request.get("cert_path")
    key_path = request.get("key_path")
    if not cert_path or not key_path:
        raise SystemExit(f"ACME request missing cert/key path: {request}")

    os.makedirs(os.path.dirname(cert_path), exist_ok=True)
    os.makedirs(os.path.dirname(key_path), exist_ok=True)
    install_cmd = [
        acme_bin,
        "--install-cert",
        "-d", request.get("main_domain") or domains[0],
        "--fullchain-file", cert_path,
        "--key-file", key_path,
        "--reloadcmd", reload_hook,
    ]
    if str(request.get("key_type") or "").startswith("ec-"):
        install_cmd.insert(4, "--ecc")
    subprocess.run(install_cmd, check=True, env=request_env)
PY

install -m 0644 "${config_dir}/systemd/xray.service" /etc/systemd/system/xray.service
install -m 0644 "${config_dir}/systemd/sing-box.service" /etc/systemd/system/sing-box.service
install -m 0644 "${config_dir}/systemd/cloudflared.service" /etc/systemd/system/cloudflared.service

systemctl daemon-reload
"${bin_dir}/xray" run -test -c "${config_dir}/xray.json"
ENABLE_DEPRECATED_LEGACY_DNS_SERVERS=true \
ENABLE_DEPRECATED_MISSING_DOMAIN_RESOLVER=true \
ENABLE_DEPRECATED_LEGACY_DOMAIN_STRATEGY_OPTIONS=true \
  "${bin_dir}/sing-box" check -c "${config_dir}/sing-box.json"

printf 'LAST_APPLY_AT=%s\nXRAY_VERSION=%s\nSINGBOX_VERSION=%s\n' \
  "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
  "${xray_tag}" \
  "${singbox_tag}" > "${state_dir}/last_apply.env"

if [[ "${skip_start}" != "true" ]]; then
  systemctl enable xray.service sing-box.service >/dev/null 2>&1 || true
  systemctl restart xray.service
  systemctl restart sing-box.service
  systemctl is-active --quiet xray.service
  systemctl is-active --quiet sing-box.service
fi

trap - ERR
REMOTE
)" \
    "${APPLY_RUNTIME_DIR}" \
    "${APPLY_REMOTE_PACKAGE}" \
    "${APPLY_RELEASE_ID}" \
    "${xray_url}" \
    "${singbox_url}" \
    "${APPLY_SKIP_START}" \
    "${APPLY_XRAY_TAG}" \
    "${APPLY_SINGBOX_TAG}" \
    "${APPLY_TARGET_ID}" \
    "${cert_dir}"
}

show_apply_result() {
  info "Apply completed for ${APPLY_TARGET_ID}"
  print_kv "Target" "${APPLY_TARGET_ID} (${TARGET_NAME})"
  print_kv "Remote host" "${TARGET_SSH_HOST}"
  print_kv "Remote arch" "${APPLY_REMOTE_ARCH}"
  print_kv "Xray version" "${APPLY_XRAY_TAG}"
  print_kv "Sing-box version" "${APPLY_SINGBOX_TAG}"
  print_kv "Runtime dir" "${APPLY_RUNTIME_DIR}"
  print_kv "Quick command" "biu"
  print_kv "Skipped start" "${APPLY_SKIP_START}"
}

run_apply() {
  parse_apply_args "$@"
  require_apply_dependencies
  ensure_real_secrets
  run_validation
  render_artifacts

  if rg -n 'replace-me' "${OUTPUT_DIR_DEFAULT}/manifest.json" >/dev/null 2>&1; then
    die "apply 已拒绝：manifest.json 仍包含占位值，请先补齐 secrets.env 和节点参数"
  fi
  if [[ -f "${OUTPUT_DIR_DEFAULT}/acme-plan.json" ]] && rg -n 'replace-me' "${OUTPUT_DIR_DEFAULT}/acme-plan.json" >/dev/null 2>&1; then
    die "apply 已拒绝：acme-plan.json 仍包含占位值，请先补齐当前目标使用到的证书参数"
  fi

  build_target_transport "${APPLY_TARGET_ID}"
  require_apply_dependencies
  prepare_apply_release
  remote_detect_arch
  remote_preflight_checks
  package_runtime_payload
  trap cleanup_apply_package EXIT
  upload_runtime_payload
  remote_apply_release
  cleanup_apply_package
  trap - EXIT
  show_apply_result
}
