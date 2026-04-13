#!/usr/bin/env bash

parse_cert_args() {
  CERT_TARGET_ID="$(app_env_value DEFAULT_TARGET)"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --target)
        [[ $# -ge 2 ]] || die "Missing value for --target"
        CERT_TARGET_ID="$2"
        shift 2
        ;;
      *)
        die "Unknown cert option: $1"
        ;;
    esac
  done
}

ensure_acme_ready() {
  run_validation
  render_artifacts

  [[ -f "${OUTPUT_DIR_DEFAULT}/acme-plan.json" ]] || die "No acme-plan.json rendered yet"
  if rg -n '"target":[[:space:]]*"'"${CERT_TARGET_ID}"'"' "${OUTPUT_DIR_DEFAULT}/acme-plan.json" >/dev/null 2>&1; then
    :
  else
    die "Target ${CERT_TARGET_ID} has no ACME-enabled nodes in acme-plan.json"
  fi

  if rg -n 'example\.com|you@example\.com|replace-me' "${OUTPUT_DIR_DEFAULT}/acme-plan.json" >/dev/null 2>&1; then
    die "acme-plan.json still contains placeholder domain/email/value; please update node hostnames and ACME email first"
  fi
}

print_cert_plan_for_target() {
  local target_id="$1"
  ruby - "${OUTPUT_DIR_DEFAULT}/acme-plan.json" "${target_id}" <<'RUBY'
require "json"

plan = JSON.parse(File.read(ARGV[0]))
target_id = ARGV[1]
rows = Array(plan).select { |item| item["target"] == target_id }

if rows.empty?
  puts "No ACME plan for target #{target_id}"
  exit 0
end

puts "ACME 计划目标: #{target_id}"
rows.each do |item|
  puts "-" * 72
  puts "节点: #{item["node_id"]}"
  puts "域名: #{Array(item["domains"]).join(", ")}"
  puts "方式: #{item["challenge"]}"
  puts "端口: #{item["standalone_port"]}" if item["challenge"] == "standalone"
  puts "DNS提供商: #{item["dns_provider"]}" if item["challenge"] == "dns"
  puts "证书路径: #{item["cert_path"]}"
  puts "私钥路径: #{item["key_path"]}"
  puts "CA: #{item["server"]}"
  puts "邮箱: #{item["email"]}"
end
RUBY
}

show_cert_plan() {
  parse_cert_args "$@"
  run_validation
  render_artifacts
  print_cert_plan_for_target "${CERT_TARGET_ID}"
}

remote_acme_script() {
  cat <<'REMOTE'
set -euo pipefail

runtime_dir="$1"
target_id="$2"
action="$3"
cert_dir="$4"

bin_dir="${runtime_dir}/bin"
output_dir="${runtime_dir}/output"
state_dir="${runtime_dir}/state"
mkdir -p "${bin_dir}" "${cert_dir}" "${state_dir}"

apt-get update
apt-get install -y ca-certificates curl socat python3 openssl

cat > "${bin_dir}/reload-certs.sh" <<'HOOK'
#!/usr/bin/env bash
set -euo pipefail
systemctl try-restart xray.service >/dev/null 2>&1 || true
systemctl try-restart sing-box.service >/dev/null 2>&1 || true
HOOK
chmod 0755 "${bin_dir}/reload-certs.sh"

python3 - "${output_dir}/acme-plan.json" "${target_id}" "${action}" "${bin_dir}/reload-certs.sh" <<'PY'
import json
import os
import shlex
import subprocess
import sys

plan_path = sys.argv[1]
target_id = sys.argv[2]
action = sys.argv[3]
reload_hook = sys.argv[4]

if not os.path.exists(plan_path):
    raise SystemExit("missing acme-plan.json on remote target")

with open(plan_path, "r", encoding="utf-8") as fh:
    requests = [item for item in json.load(fh) if item.get("target") == target_id]

if not requests:
    raise SystemExit(f"no acme plan entries for {target_id}")

first = requests[0]
install_dir = first.get("install_dir") or "/root/.acme.sh"
acme_bin = os.path.join(install_dir, "acme.sh")
email = first.get("email") or ""
env = os.environ.copy()

if not os.path.exists(acme_bin):
    install_cmd = "curl -fsSL https://get.acme.sh | sh -s email=" + shlex.quote(email)
    subprocess.run(["bash", "-lc", install_cmd], check=True, env=env)

if action == "renew":
    subprocess.run([acme_bin, "--cron", "--home", install_dir], check=True, env=env)
    sys.exit(0)

for request in requests:
    request_env = env.copy()
    for key, value in (request.get("dns_env") or {}).items():
        if value:
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

printf 'LAST_CERT_ACTION=%s\nLAST_CERT_AT=%s\n' \
  "${action}" \
  "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" > "${state_dir}/last_cert.env"
REMOTE
}

run_remote_acme_action() {
  local action="$1"
  local cert_dir
  cert_dir="$(app_env_value CERT_DIR)"

  build_target_transport "${CERT_TARGET_ID}"
  require_transport_dependencies

  if [[ "${TARGET_ROLE}" == "reserved-host" ]]; then
    die "证书命令当前默认只对 clean-host 开放，避免误碰保留主机 ${CERT_TARGET_ID}"
  fi

  if [[ "${action}" == "issue" ]]; then
    assert_remote_acme_preflight
  fi

  run_target_sudo_script "$(remote_acme_script)" \
    "${APPLY_RUNTIME_DIR:-$(app_env_value RUNTIME_DIR)}" \
    "${CERT_TARGET_ID}" \
    "${action}" \
    "${cert_dir}"
}

run_cert_issue() {
  parse_cert_args "$@"
  ensure_real_secrets
  ensure_acme_ready
  build_target_transport "${CERT_TARGET_ID}"
  require_transport_dependencies
  package_runtime_payload
  trap cleanup_apply_package EXIT
  upload_runtime_payload
  run_remote_acme_action issue
  cleanup_apply_package
  trap - EXIT
  info "ACME 签发完成: ${CERT_TARGET_ID}"
}

run_cert_renew() {
  parse_cert_args "$@"
  ensure_real_secrets
  ensure_acme_ready
  build_target_transport "${CERT_TARGET_ID}"
  require_transport_dependencies
  package_runtime_payload
  trap cleanup_apply_package EXIT
  upload_runtime_payload
  run_remote_acme_action renew
  cleanup_apply_package
  trap - EXIT
  info "ACME 续期命令已执行: ${CERT_TARGET_ID}"
}

show_cert_status() {
  parse_cert_args "$@"
  ensure_real_secrets
  run_validation
  render_artifacts
  build_target_transport "${CERT_TARGET_ID}"
  require_transport_dependencies

  printf '证书状态目标: %s\n' "${CERT_TARGET_ID}"
  printf '远端主机: %s\n' "${TARGET_SSH_HOST}"
  printf '%s\n' '------------------------------------------------------------------------'
  print_cert_plan_for_target "${CERT_TARGET_ID}"
  printf '%s\n' '------------------------------------------------------------------------'

  remote_exec "sudo bash -lc 'if [ -x /root/.acme.sh/acme.sh ]; then /root/.acme.sh/acme.sh --list; else echo acme.sh-not-installed; fi'" || true

  printf '%s\n' '------------------------------------------------------------------------'
  ruby - "${OUTPUT_DIR_DEFAULT}/acme-plan.json" "${CERT_TARGET_ID}" <<'RUBY' | while IFS=$'\t' read -r node_id cert_path key_path; do
require "json"

plan = JSON.parse(File.read(ARGV[0]))
target_id = ARGV[1]
Array(plan).each do |item|
  next unless item["target"] == target_id
  puts [item["node_id"], item["cert_path"], item["key_path"]].join("\t")
end
RUBY
    [[ -n "${node_id}" ]] || continue
    printf '节点: %s\n' "${node_id}"
    if remote_exec "test -f $(printf '%q' "${cert_path}")"; then
      remote_exec "openssl x509 -in $(printf '%q' "${cert_path}") -noout -subject -issuer -enddate" || true
    else
      printf '证书文件不存在: %s\n' "${cert_path}"
    fi
    if remote_exec "test -f $(printf '%q' "${key_path}")"; then
      printf '私钥文件: %s\n' "${key_path}"
    else
      printf '私钥文件不存在: %s\n' "${key_path}"
    fi
    printf '%s\n' '------------------------------------------------------------------------'
  done
}
