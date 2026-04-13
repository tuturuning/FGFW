#!/usr/bin/env bash

required_config_files=(
  "${CONFIG_DIR}/app.env.example"
  "${CONFIG_DIR}/targets.yaml"
  "${CONFIG_DIR}/nodes.yaml"
  "${CONFIG_DIR}/outbounds.yaml"
  "${CONFIG_DIR}/routing.yaml"
  "${CONFIG_DIR}/dns.yaml"
  "${CONFIG_DIR}/acme.yaml"
  "${CONFIG_DIR}/argo.yaml"
  "${CONFIG_DIR}/warp.yaml"
  "${CONFIG_DIR}/export.yaml"
  "${CONFIG_DIR}/secrets.env.example"
)

validate_required_files() {
  local file
  for file in "${required_config_files[@]}"; do
    require_file "${file}"
  done
}

validate_dependencies() {
  command -v ruby >/dev/null 2>&1 || die "ruby is required for manifest compilation"
  command -v rg >/dev/null 2>&1 || die "rg is required for config validation"
}

validate_targets_yaml() {
  local file="${CONFIG_DIR}/targets.yaml"
  rg -q '^[[:space:]]*targets:' "${file}" || die "targets.yaml is missing root key 'targets:'"
  rg -q '^[[:space:]]*-[[:space:]]*id:' "${file}" || die "targets.yaml has no target entries"
}

validate_nodes_yaml() {
  local file="${CONFIG_DIR}/nodes.yaml"
  rg -q '^[[:space:]]*nodes:' "${file}" || die "nodes.yaml is missing root key 'nodes:'"
  rg -q 'protocol:[[:space:]]+(vless|vmess|trojan|hysteria2|tuic|ss2022|shadowsocks)' "${file}" || \
    die "nodes.yaml does not contain any supported protocol entries"
}

validate_outbounds_yaml() {
  local file="${CONFIG_DIR}/outbounds.yaml"
  rg -q '^[[:space:]]*outbounds:' "${file}" || die "outbounds.yaml is missing root key 'outbounds:'"
  rg -q 'role:[[:space:]]+(direct|blocked|vps-v4|vps-v6|residential-static|residential-dynamic|warp-v4|warp-v6|warp-auto)' "${file}" || \
    die "outbounds.yaml does not contain any recognized outbound roles"
}

validate_dns_yaml() {
  local file="${CONFIG_DIR}/dns.yaml"
  rg -q '^[[:space:]]*dns:' "${file}" || die "dns.yaml is missing root key 'dns:'"
  rg -q '^[[:space:]]*-[[:space:]]*id:[[:space:]]+dns-main' "${file}" || die "dns.yaml is missing dns-main"
}

validate_acme_yaml() {
  local file="${CONFIG_DIR}/acme.yaml"
  rg -q '^[[:space:]]*acme:' "${file}" || die "acme.yaml is missing root key 'acme:'"
  rg -q 'default_challenge:[[:space:]]+(standalone|dns)' "${file}" || \
    die "acme.yaml must define default_challenge as standalone or dns"
}

validate_export_yaml() {
  local file="${CONFIG_DIR}/export.yaml"
  rg -q '^[[:space:]]*exports:' "${file}" || die "export.yaml is missing root key 'exports:'"
  rg -q 'template:' "${file}" || warn "export.yaml currently has no external URL templates"
}

validate_topology() {
  local tmp_dir
  local secrets_file
  tmp_dir="$(mktemp -d)"
  secrets_file="$(resolve_secrets_file)"

  ruby "${SCRIPT_DIR}/lib/render_manifest.rb" \
    "${CONFIG_DIR}" \
    "${tmp_dir}" \
    "${secrets_file}" >/dev/null

  ruby "${SCRIPT_DIR}/lib/render_runtime_configs.rb" \
    "${tmp_dir}/manifest.json" \
    "${tmp_dir}/config" \
    "${PROJECT_ROOT}/deploy/domains" >/dev/null

  rm -rf "${tmp_dir}"
}

run_validation() {
  info "Validating deploy scaffold..."
  validate_dependencies
  validate_required_files
  validate_targets_yaml
  validate_nodes_yaml
  validate_outbounds_yaml
  validate_dns_yaml
  validate_acme_yaml
  validate_export_yaml
  validate_topology
  info "Validation passed."
}

show_status() {
  print_kv "Project root" "${PROJECT_ROOT}"
  print_kv "Config dir" "${CONFIG_DIR}"
  print_kv "Runtime dir" "${RUNTIME_DIR_DEFAULT}"
  print_kv "Output dir" "${OUTPUT_DIR_DEFAULT}"
  print_kv "Secrets file" "$(resolve_secrets_file)"
  if [[ -d "${RUNTIME_DIR_DEFAULT}" ]]; then
    print_kv "Runtime exists" "yes"
  else
    print_kv "Runtime exists" "no"
  fi
  if [[ -f "${OUTPUT_DIR_DEFAULT}/manifest.json" ]]; then
    print_kv "Manifest" "${OUTPUT_DIR_DEFAULT}/manifest.json"
  else
    print_kv "Manifest" "not rendered"
  fi
}
