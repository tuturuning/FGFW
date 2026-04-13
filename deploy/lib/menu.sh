#!/usr/bin/env bash

menu_init_theme() {
  MENU_RESET=''
  MENU_BOLD=''
  MENU_CYAN=''
  MENU_GREEN=''
  MENU_YELLOW=''
  MENU_RED=''

  if [[ -t 1 ]] && [[ "${TERM:-}" != "dumb" ]] && [[ -z "${NO_COLOR:-}" ]]; then
    MENU_RESET=$'\033[0m'
    MENU_BOLD=$'\033[1m'
    MENU_CYAN=$'\033[36m'
    MENU_GREEN=$'\033[32m'
    MENU_YELLOW=$'\033[33m'
    MENU_RED=$'\033[31m'
  fi
}

menu_color() {
  local color="$1"
  shift
  printf '%b%s%b' "${color}" "$*" "${MENU_RESET}"
}

menu_width() {
  local cols
  cols="$(tput cols 2>/dev/null || true)"
  if [[ -n "${cols}" ]] && [[ "${cols}" =~ ^[0-9]+$ ]] && (( cols >= 72 )); then
    printf '%s\n' "${cols}"
  else
    printf '94\n'
  fi
}

menu_rule() {
  local char="${1:--}"
  local width
  width="$(menu_width)"
  printf '%*s\n' "${width}" '' | tr ' ' "${char}"
}

menu_pause() {
  if [[ -t 0 ]] && [[ -t 1 ]]; then
    printf '\n'
    read -r -p '按回车继续...' _
  fi
}

menu_clear() {
  if [[ -t 1 ]] && command -v clear >/dev/null 2>&1; then
    clear
  fi
}

menu_prompt() {
  local label="$1"
  local default_value="${2:-}"
  local value
  if [[ -n "${default_value}" ]]; then
    read -r -p "${label} [默认: ${default_value}]: " value
    printf '%s\n' "${value:-${default_value}}"
  else
    read -r -p "${label}: " value
    printf '%s\n' "${value}"
  fi
}

menu_prompt_required() {
  local label="$1"
  local default_value="${2:-}"
  local value
  while true; do
    value="$(menu_prompt "${label}" "${default_value}")"
    if [[ -n "${value}" ]]; then
      printf '%s\n' "${value}"
      return 0
    fi
    warn '该项不能为空，请重新输入。'
  done
}

menu_prompt_bool() {
  local label="$1"
  local default_value="${2:-true}"
  local value
  value="$(menu_prompt "${label} (true/false)" "${default_value}")"
  case "${value}" in
    true|false)
      printf '%s\n' "${value}"
      ;;
    *)
      warn "无效布尔值，已使用默认值 ${default_value}"
      printf '%s\n' "${default_value}"
      ;;
  esac
}

menu_env_value() {
  local key="$1"
  local file="${CONFIG_DIR}/app.env.example"
  awk -F= -v key="${key}" '$1 == key { print substr($0, index($0, "=") + 1); exit }' "${file}"
}

menu_git_version() {
  local version='dev'
  if git -C "${PROJECT_ROOT}" rev-parse --short HEAD >/dev/null 2>&1; then
    version="$(git -C "${PROJECT_ROOT}" rev-parse --short HEAD)"
    if [[ -n "$(git -C "${PROJECT_ROOT}" status --porcelain 2>/dev/null)" ]]; then
      version="${version}-dirty"
    fi
  elif [[ -f "${PROJECT_ROOT}/deploy/VERSION" ]]; then
    version="$(<"${PROJECT_ROOT}/deploy/VERSION")"
  fi
  printf '%s\n' "${version}"
}

menu_status_text() {
  local ok="$1"
  local text
  if [[ "${ok}" == "yes" ]]; then
    text='已生成'
    menu_color "${MENU_GREEN}" "${text}"
  else
    text='未生成'
    menu_color "${MENU_YELLOW}" "${text}"
  fi
}

menu_bool_text() {
  local value="$1"
  if [[ "${value}" == "true" ]]; then
    menu_color "${MENU_GREEN}" '开启'
  else
    menu_color "${MENU_YELLOW}" '关闭'
  fi
}

menu_file_status() {
  local path="$1"
  if [[ -f "${path}" ]]; then
    menu_status_text 'yes'
  else
    menu_status_text 'no'
  fi
}

menu_value_or_placeholder() {
  local value="${1:-}"
  if [[ -n "${value}" ]]; then
    printf '%s\n' "${value}"
  else
    printf '未配置\n'
  fi
}

menu_safe_target_field() {
  local target_id="$1"
  local field="$2"
  target_field "${target_id}" "${field}" 2>/dev/null || true
}

menu_repo_url() {
  local value
  value="$(menu_env_value PROJECT_REPO_URL)"
  menu_value_or_placeholder "${value}"
}

menu_os_pretty_name() {
  local value
  value="$(awk -F= '/^PRETTY_NAME=/{gsub(/"/, "", $2); print $2; exit}' /etc/os-release 2>/dev/null || true)"
  if [[ -z "${value}" ]]; then
    value="$(uname -s 2>/dev/null || true)"
  fi
  menu_value_or_placeholder "${value}"
}

menu_virtualization_label() {
  local value=''
  if command -v systemd-detect-virt >/dev/null 2>&1; then
    value="$(systemd-detect-virt 2>/dev/null || true)"
  fi
  if [[ -z "${value}" || "${value}" == "none" ]]; then
    if command -v virt-what >/dev/null 2>&1; then
      value="$(virt-what 2>/dev/null | head -n 1 || true)"
    fi
  fi
  if [[ -z "${value}" || "${value}" == "none" ]]; then
    value='bare-metal'
  fi
  printf '%s\n' "${value}"
}

menu_state_value() {
  local key="$1"
  local file="${STATE_DIR_DEFAULT}/last_apply.env"
  if [[ -f "${file}" ]]; then
    awk -F= -v key="${key}" '$1 == key { print substr($0, index($0, "=") + 1); exit }' "${file}"
  fi
}

menu_installed_binary_version() {
  local name="$1"
  local path="$2"
  local first_line=''

  if [[ ! -x "${path}" ]]; then
    printf '未安装\n'
    return 0
  fi

  case "${name}" in
    xray)
      first_line="$("${path}" version 2>/dev/null | head -n 1 || true)"
      printf '%s\n' "${first_line}" | awk '{print ($2 != "" ? $2 : $0)}'
      ;;
    sing-box)
      first_line="$("${path}" version 2>/dev/null | head -n 1 || true)"
      printf '%s\n' "${first_line}" | awk '{print ($3 != "" ? $3 : $0)}'
      ;;
    cloudflared)
      first_line="$("${path}" --version 2>/dev/null | head -n 1 || true)"
      printf '%s\n' "${first_line}" | awk '{print ($3 != "" ? $3 : $0)}'
      ;;
    *)
      printf '未知\n'
      ;;
  esac
}

menu_service_state_text() {
  local service="$1"
  local unit="${service}.service"
  local state

  if ! command -v systemctl >/dev/null 2>&1; then
    printf '未知\n'
    return 0
  fi

  state="$(systemctl is-active "${unit}" 2>/dev/null || true)"
  case "${state}" in
    active)
      menu_color "${MENU_GREEN}" '运行中'
      ;;
    inactive|failed|activating|deactivating)
      menu_color "${MENU_RED}" '未运行'
      ;;
    *)
      if systemctl list-unit-files "${unit}" >/dev/null 2>&1; then
        menu_color "${MENU_YELLOW}" '未启用'
      else
        menu_color "${MENU_YELLOW}" '未安装'
      fi
      ;;
  esac
}

menu_check_mark_text() {
  local path="$1"
  if [[ -e "${path}" ]]; then
    menu_color "${MENU_GREEN}" '可用'
  else
    menu_color "${MENU_YELLOW}" '缺失'
  fi
}

menu_show_home_actions() {
  menu_rule '-'
  printf '%b\n' "$(menu_color "${MENU_BOLD}" ' FGFW 主菜单')"
  cat <<'EOF'
  1. 首次部署
  2. 日常运维
  3. 导出分享
  4. 高级配置
  5. 故障排查
EOF
  menu_rule '-'
  printf '  0. 退出 FGFW\n'
}

menu_show_script_info() {
  local script_version repo_url
  script_version="$(menu_git_version)"
  repo_url="$(menu_repo_url)"

  menu_rule '-'
  printf '%b\n' "$(menu_color "${MENU_BOLD}" ' 脚本版本 / 升级')"
  printf ' 当前脚本版本: %s\n' "${script_version}"
  printf ' GitHub 地址  : %s\n' "${repo_url}"
  printf ' 脚本升级入口: 日常运维 -> 版本与升级 -> 4\n'
  printf ' Core 升级入口: 日常运维 -> 版本与升级 -> 6\n'
}

menu_show_server_info() {
  local default_target target_name target_region public_ipv4 public_ipv6
  default_target="$(menu_env_value DEFAULT_TARGET)"
  target_name="$(menu_safe_target_field "${default_target}" name)"
  target_region="$(menu_safe_target_field "${default_target}" region)"
  public_ipv4="$(menu_safe_target_field "${default_target}" public_ipv4)"
  public_ipv6="$(menu_safe_target_field "${default_target}" public_ipv6)"

  menu_rule '-'
  printf '%b\n' "$(menu_color "${MENU_BOLD}" ' 服务器信息')"
  printf ' 主机名      : %s\n' "$(hostname 2>/dev/null || printf '未知')"
  printf ' 部署目标    : %s (%s)\n' "${default_target}" "$(menu_value_or_placeholder "${target_name}")"
  printf ' 系统版本    : %s\n' "$(menu_os_pretty_name)"
  printf ' 内核版本    : %s\n' "$(uname -r 2>/dev/null || printf '未知')"
  printf ' CPU 架构    : %s\n' "$(uname -m 2>/dev/null || printf '未知')"
  printf ' 虚拟化类型  : %s\n' "$(menu_virtualization_label)"
  printf ' IPv4        : %s\n' "$(menu_value_or_placeholder "${public_ipv4}")"
  printf ' IPv6        : %s\n' "$(menu_value_or_placeholder "${public_ipv6}")"
  printf ' 目标地区    : %s\n' "$(menu_value_or_placeholder "${target_region}")"
}

menu_show_core_versions() {
  local xray_target singbox_target cloudflared_target
  local xray_installed singbox_installed cloudflared_installed
  xray_target="$(menu_env_value XRAY_VERSION)"
  singbox_target="$(menu_env_value SINGBOX_VERSION)"
  cloudflared_target="$(menu_env_value CLOUDFLARED_VERSION)"

  xray_installed="$(menu_installed_binary_version xray "${RUNTIME_DIR_DEFAULT}/bin/xray")"
  singbox_installed="$(menu_installed_binary_version sing-box "${RUNTIME_DIR_DEFAULT}/bin/sing-box")"
  cloudflared_installed="$(menu_installed_binary_version cloudflared "${RUNTIME_DIR_DEFAULT}/bin/cloudflared")"

  menu_rule '-'
  printf '%b\n' "$(menu_color "${MENU_BOLD}" ' Core 版本')"
  printf ' xray        : 已安装 %-16s 目标 %s\n' "${xray_installed}" "$(menu_value_or_placeholder "${xray_target}")"
  printf ' sing-box    : 已安装 %-16s 目标 %s\n' "${singbox_installed}" "$(menu_value_or_placeholder "${singbox_target}")"
  printf ' cloudflared : 已安装 %-16s 目标 %s\n' "${cloudflared_installed}" "$(menu_value_or_placeholder "${cloudflared_target}")"
}

menu_show_runtime_status() {
  local last_apply_at='' last_cert_at=''
  last_apply_at="$(menu_state_value LAST_APPLY_AT)"
  if [[ -f "${STATE_DIR_DEFAULT}/last_cert.env" ]]; then
    last_cert_at="$(<"${STATE_DIR_DEFAULT}/last_cert.env")"
  fi

  menu_rule '-'
  printf '%b\n' "$(menu_color "${MENU_BOLD}" ' 运行状态')"
  printf ' xray        : %s\n' "$(menu_service_state_text xray)"
  printf ' sing-box    : %s\n' "$(menu_service_state_text sing-box)"
  printf ' cloudflared : %s\n' "$(menu_service_state_text cloudflared)"
  printf ' manifest    : %s\n' "$(menu_check_mark_text "${OUTPUT_DIR_DEFAULT}/manifest.json")"
  printf ' 订阅导出    : %s\n' "$(menu_check_mark_text "${OUTPUT_DIR_DEFAULT}/clash-verge-redir-host.yaml")"
  printf ' 最近 Apply  : %s\n' "$(menu_value_or_placeholder "${last_apply_at}")"
  printf ' 最近证书处理: %s\n' "$(menu_value_or_placeholder "${last_cert_at}")"
}

menu_show_version_overview() {
  menu_clear
  menu_show_banner
  menu_show_script_info
  menu_show_core_versions
  menu_show_runtime_status
  menu_rule '~'
}

menu_check_script_update() {
  if git -C "${PROJECT_ROOT}" rev-parse --git-dir >/dev/null 2>&1 && git -C "${PROJECT_ROOT}" remote get-url origin >/dev/null 2>&1; then
    info "Checking script updates..."
    git -C "${PROJECT_ROOT}" fetch --quiet origin || {
      warn '脚本更新检查失败'
      return 0
    }
    local local_rev remote_rev
    local_rev="$(git -C "${PROJECT_ROOT}" rev-parse HEAD 2>/dev/null || true)"
    remote_rev="$(git -C "${PROJECT_ROOT}" rev-parse '@{u}' 2>/dev/null || true)"
    if [[ -n "${local_rev}" && -n "${remote_rev}" && "${local_rev}" == "${remote_rev}" ]]; then
      info "FGFW script is already up to date."
    else
      warn "FGFW script has updates available. Local=$(printf '%.7s' "${local_rev}") Remote=$(printf '%.7s' "${remote_rev}")"
    fi
  else
    warn '当前为打包部署模式，暂不支持自动检查脚本更新。'
  fi
}

menu_upgrade_script() {
  if git -C "${PROJECT_ROOT}" rev-parse --git-dir >/dev/null 2>&1 && git -C "${PROJECT_ROOT}" remote get-url origin >/dev/null 2>&1; then
    info "Updating FGFW script repository..."
    git -C "${PROJECT_ROOT}" pull --ff-only
  else
    warn '当前为打包部署模式，暂不支持 git 自更新。请重新同步 deploy 包。'
  fi
}

menu_show_upgrade_history() {
  menu_show_banner
  menu_rule '-'
  printf '%b\n' "$(menu_color "${MENU_BOLD}" ' 最近升级记录')"
  if [[ -f "${STATE_DIR_DEFAULT}/last_apply.env" ]]; then
    cat "${STATE_DIR_DEFAULT}/last_apply.env"
  else
    printf ' 尚无升级记录\n'
  fi
  menu_rule '~'
}

menu_show_recent_logs() {
  menu_show_banner
  menu_rule '-'
  printf '%b\n' "$(menu_color "${MENU_BOLD}" ' 最近日志')"
  if command -v journalctl >/dev/null 2>&1; then
    journalctl --no-pager -u xray.service -u sing-box.service -u cloudflared.service -n 40 2>/dev/null || true
  else
    printf ' 当前环境不支持 journalctl\n'
  fi
  menu_rule '~'
}

menu_collect_targets() {
  ruby - "${CONFIG_DIR}/targets.yaml" "$(menu_env_value DEFAULT_TARGET)" <<'RUBY'
require "yaml"

file = ARGV[0]
default_target = ARGV[1]
targets = Array((YAML.load_file(file) || {})["targets"])

puts "SUMMARY=#{targets.size}|#{default_target}"
targets.each do |target|
  marker =
    if target["id"] == default_target
      "默认"
    elsif target["role"] == "reserved-host"
      "保留"
    else
      "目标"
    end

  preserve = []
  ports = Array(target.dig("preserve", "ports"))
  services = Array(target.dig("preserve", "services"))
  paths = Array(target.dig("preserve", "paths"))
  notes = Array(target.dig("preserve", "notes"))
  preserve << "端口 #{ports.join('/')}" unless ports.empty?
  preserve << "服务 #{services.join(',')}" unless services.empty?
  preserve << "路径 #{paths.join(',')}" unless paths.empty?
  preserve << "备注 #{notes.join(' | ')}" unless notes.empty?

  puts [
    marker,
    target["id"],
    target["name"],
    target["region"],
    target["role"],
    target["public_ipv4"] || "-",
    target["public_ipv6"] || "-",
    preserve.join(" ; ")
  ].join("\t")
end
RUBY
}

menu_collect_nodes() {
  local manifest="${OUTPUT_DIR_DEFAULT}/manifest.json"
  if [[ -f "${manifest}" ]]; then
    ruby - "${manifest}" <<'RUBY'
require "json"

data = JSON.parse(File.read(ARGV[0]))
nodes = Array(data["nodes"])
enabled = nodes.select { |node| node["enabled"] }
xray = enabled.count { |node| node["core"] == "xray" }
singbox = enabled.count { |node| node["core"] == "sing-box" }

puts "SUMMARY=#{enabled.size}|#{nodes.size}|#{xray}|#{singbox}"
enabled.each do |node|
  protocol = [node["protocol"], node["security"]].compact.join("+").upcase
  port = node.dig("listen", "port") || "-"
  groups = Array(node.dig("export", "groups")).join(",")
  puts [node["id"], protocol, node["target"], port, groups].join("\t")
end
RUBY
  else
    ruby - "${CONFIG_DIR}/nodes.yaml" <<'RUBY'
require "yaml"

nodes = Array((YAML.load_file(ARGV[0]) || {})["nodes"])
enabled = nodes.select { |node| node["enabled"] }
xray = enabled.count { |node| node["core"] == "xray" }
singbox = enabled.count { |node| node["core"] == "sing-box" }

puts "SUMMARY=#{enabled.size}|#{nodes.size}|#{xray}|#{singbox}"
enabled.each do |node|
  protocol = [node["protocol"], node["security"]].compact.join("+").upcase
  port = node.dig("listen", "port") || "-"
  groups = Array(node.dig("export", "groups")).join(",")
  puts [node["id"], protocol, node["target"], port, groups].join("\t")
end
RUBY
  fi
}

menu_collect_outbounds() {
  ruby - "${CONFIG_DIR}/outbounds.yaml" <<'RUBY'
require "yaml"

data = YAML.load_file(ARGV[0]) || {}
outbounds = Array(data["outbounds"])
groups = Array(data["outbound_groups"])
enabled = outbounds.select { |outbound| outbound["enabled"] }
residential = outbounds.select { |outbound| outbound["role"].to_s.start_with?("residential") }

puts "SUMMARY=#{enabled.size}|#{outbounds.size}|#{groups.size}|#{residential.size}"
enabled.each do |outbound|
  stack = outbound["stack"] || "dual"
  server = outbound["server"] || "-"
  puts [outbound["id"], outbound["role"], outbound["type"], stack, server].join("\t")
end
groups.each do |group|
  members = Array(group["members"]).join(",")
  puts "GROUP\t#{group["id"]}\t#{group["type"]}\t#{members}"
end
RUBY
}

menu_collect_dns() {
  ruby - "${CONFIG_DIR}/dns.yaml" <<'RUBY'
require "yaml"

data = YAML.load_file(ARGV[0]) || {}
dns = data["dns"] || {}
servers = Array(dns["servers"])
policies = dns["policies"] || {}
global_policy = policies["global"] || {}
clash_export = dns["clash_export"] || {}
redir = clash_export.dig("redir_host", "enhanced_mode") || "-"
fake_ip = clash_export.dig("fake_ip", "enhanced_mode") || "-"

puts "SUMMARY=#{servers.size}|#{policies.size}|#{global_policy["server"] || "-"}|#{redir}|#{fake_ip}"
servers.each do |server|
  puts [server["id"], server["type"], server["address"]].join("\t")
end
RUBY
}

menu_collect_routing() {
  ruby - "${CONFIG_DIR}/routing.yaml" <<'RUBY'
require "yaml"

data = YAML.load_file(ARGV[0]) || {}
routing = data["routing"] || {}
defaults = routing["defaults"] || {}
rules = Array(routing["rules"])
enabled = rules.select { |rule| rule["enabled"] != false }

puts "SUMMARY=#{enabled.size}|#{rules.size}|#{defaults["final_outbound"] || "-"}|#{defaults["block_bittorrent"]}|#{defaults["block_udp_443"]}"
enabled.each do |rule|
  action = rule["action"] || {}
  outbound = action["outbound"] || "-"
  match = rule["match"] || {}
  label =
    if match["domain_group"]
      "域名组 #{match["domain_group"]}"
    elsif match["domain_groups"]
      "域名组 #{Array(match["domain_groups"]).join(',')}"
    elsif match["inbound_tags"]
      "入站 #{Array(match["inbound_tags"]).join(',')}"
    else
      "自定义匹配"
    end

  puts [rule["id"], label, outbound].join("\t")
end
RUBY
}

menu_show_banner() {
  local entry_hint='biu menu'
  if [[ ! -x /usr/local/bin/biu && ! -x /usr/bin/biu ]]; then
    entry_hint='./deploy/install.sh menu'
  fi
  menu_init_theme
  menu_rule '~'
  printf '%b\n' "$(menu_color "${MENU_BOLD}${MENU_CYAN}" ' FGFW | sing-box + xray ')"
  printf ' 入口: %s   单一事实源: manifest.json -> runtime / export / links\n' "${entry_hint}"
  menu_rule '~'
}

menu_show_overview() {
  local project_name namespace default_target xray_ver singbox_ver cloudflared_ver
  project_name="$(menu_env_value PROJECT_NAME)"
  namespace="$(menu_env_value PROJECT_NAMESPACE)"
  default_target="$(menu_env_value DEFAULT_TARGET)"
  xray_ver="$(menu_env_value XRAY_VERSION)"
  singbox_ver="$(menu_env_value SINGBOX_VERSION)"
  cloudflared_ver="$(menu_env_value CLOUDFLARED_VERSION)"

  printf ' 项目名称: %s   命名空间: %s   当前版本: %s\n' \
    "${project_name}" "${namespace}" "$(menu_git_version)"
  printf ' 默认目标: %s   Secrets: %s\n' \
    "${default_target}" "$(resolve_secrets_file)"
  printf ' 默认能力: IPv4 %s / IPv6 %s / Argo %s / WARP %s / ACME %s\n' \
    "$(menu_bool_text "$(menu_env_value ENABLE_IPV4)")" \
    "$(menu_bool_text "$(menu_env_value ENABLE_IPV6)")" \
    "$(menu_bool_text "$(menu_env_value ENABLE_ARGO)")" \
    "$(menu_bool_text "$(menu_env_value ENABLE_WARP)")" \
    "$(menu_bool_text "$(menu_env_value ENABLE_ACME)")"
  printf ' 内核版本: xray %s | sing-box %s | cloudflared %s\n' \
    "${xray_ver}" "${singbox_ver}" "${cloudflared_ver}"
}

menu_show_targets() {
  local lines summary total default_target
  mapfile -t lines < <(menu_collect_targets)
  summary="${lines[0]#SUMMARY=}"
  total="${summary%%|*}"
  default_target="${summary#*|}"

  menu_rule '-'
  printf '%b\n' "$(menu_color "${MENU_BOLD}" " 目标主机 (${total} 台，默认 ${default_target})")"
  local line
  for line in "${lines[@]:1}"; do
    IFS=$'\t' read -r marker id name region role ipv4 ipv6 preserve <<<"${line}"
    printf ' [%s] %-8s %-14s 区域 %-4s 角色 %-14s IPv4 %s\n' \
      "${marker}" "${id}" "${name}" "${region}" "${role}" "${ipv4}"
    printf '      IPv6 %s\n' "${ipv6}"
    if [[ -n "${preserve}" ]]; then
      printf '      保留 %s\n' "${preserve}"
    fi
  done
}

menu_show_nodes() {
  local lines summary enabled total xray_count singbox_count
  mapfile -t lines < <(menu_collect_nodes)
  summary="${lines[0]#SUMMARY=}"
  IFS='|' read -r enabled total xray_count singbox_count <<<"${summary}"

  menu_rule '-'
  printf '%b\n' "$(menu_color "${MENU_BOLD}" " 节点矩阵 (已启用 ${enabled}/${total}，xray ${xray_count}，sing-box ${singbox_count})")"
  local line
  if (( ${#lines[@]} == 1 )); then
    printf ' 暂无已启用节点\n'
    return
  fi
  for line in "${lines[@]:1}"; do
    IFS=$'\t' read -r id protocol target port groups <<<"${line}"
    printf ' - %-22s %-18s 目标 %-8s 端口 %-6s 导出组 %s\n' \
      "${id}" "${protocol}" "${target}" "${port}" "${groups}"
  done
}

menu_show_policy() {
  local outbound_lines dns_lines routing_lines outbound_summary dns_summary routing_summary
  local enabled_outbounds total_outbounds outbound_groups residential_count
  local dns_servers dns_policies dns_default clash_redir clash_fake
  local enabled_rules total_rules final_outbound block_bt block_udp_443

  mapfile -t outbound_lines < <(menu_collect_outbounds)
  mapfile -t dns_lines < <(menu_collect_dns)
  mapfile -t routing_lines < <(menu_collect_routing)

  outbound_summary="${outbound_lines[0]#SUMMARY=}"
  dns_summary="${dns_lines[0]#SUMMARY=}"
  routing_summary="${routing_lines[0]#SUMMARY=}"

  IFS='|' read -r enabled_outbounds total_outbounds outbound_groups residential_count <<<"${outbound_summary}"
  IFS='|' read -r dns_servers dns_policies dns_default clash_redir clash_fake <<<"${dns_summary}"
  IFS='|' read -r enabled_rules total_rules final_outbound block_bt block_udp_443 <<<"${routing_summary}"

  menu_rule '-'
  printf '%b\n' "$(menu_color "${MENU_BOLD}" ' 出口 / DNS / 分流摘要')"
  printf ' 出口: 已启用 %s/%s，分组 %s，住宅出口候选 %s\n' \
    "${enabled_outbounds}" "${total_outbounds}" "${outbound_groups}" "${residential_count}"
  printf ' DNS : 服务器 %s，策略 %s，默认 %s，Clash 模式 %s + %s\n' \
    "${dns_servers}" "${dns_policies}" "${dns_default}" "${clash_redir}" "${clash_fake}"
  printf ' 分流: 已启用 %s/%s，默认出口 %s，BT 阻断 %s，UDP/443 阻断 %s\n' \
    "${enabled_rules}" "${total_rules}" "${final_outbound}" "${block_bt}" "${block_udp_443}"

  local line shown=0
  for line in "${routing_lines[@]:1}"; do
    IFS=$'\t' read -r id label outbound <<<"${line}"
    printf ' - %-16s %-20s -> %s\n' "${id}" "${label}" "${outbound}"
    shown=$((shown + 1))
    if (( shown >= 3 )); then
      break
    fi
  done
}

menu_show_runtime() {
  local secrets_label
  secrets_label="$(resolve_secrets_file)"

  menu_rule '-'
  printf '%b\n' "$(menu_color "${MENU_BOLD}" ' 运行时产物 / 导出状态')"
  printf ' Runtime 目录: %s\n' "${RUNTIME_DIR_DEFAULT}"
  printf ' Secrets 来源: %s\n' "${secrets_label}"
  printf ' manifest.json     %s\n' "$(menu_file_status "${OUTPUT_DIR_DEFAULT}/manifest.json")"
  printf ' xray.json         %s\n' "$(menu_file_status "${RUNTIME_CONFIG_DIR_DEFAULT}/xray.json")"
  printf ' sing-box.json     %s\n' "$(menu_file_status "${RUNTIME_CONFIG_DIR_DEFAULT}/sing-box.json")"
  printf ' systemd/xray      %s\n' "$(menu_file_status "${RUNTIME_SYSTEMD_DIR_DEFAULT}/xray.service")"
  printf ' systemd/sing-box  %s\n' "$(menu_file_status "${RUNTIME_SYSTEMD_DIR_DEFAULT}/sing-box.service")"
  printf ' systemd/cloudflared %s\n' "$(menu_file_status "${RUNTIME_SYSTEMD_DIR_DEFAULT}/cloudflared.service")"
  printf ' acme-plan.json    %s\n' "$(menu_file_status "${OUTPUT_DIR_DEFAULT}/acme-plan.json")"
  printf ' links.txt         %s\n' "$(menu_file_status "${OUTPUT_DIR_DEFAULT}/links.txt")"
  printf ' v2rayN            %s\n' "$(menu_file_status "${OUTPUT_DIR_DEFAULT}/nodes-v2rayn.txt")"
  printf ' Shadowrocket      %s\n' "$(menu_file_status "${OUTPUT_DIR_DEFAULT}/nodes-shadowrocket.txt")"
  printf ' Clash redir-host  %s\n' "$(menu_file_status "${OUTPUT_DIR_DEFAULT}/clash-verge-redir-host.yaml")"
  printf ' Clash fake-ip     %s\n' "$(menu_file_status "${OUTPUT_DIR_DEFAULT}/clash-verge-fake-ip.yaml")"
}

menu_show_options() {
  menu_rule '-'
  printf '%b\n' "$(menu_color "${MENU_BOLD}" ' 主菜单')"
  cat <<'EOF'
  1. 环境探测
  2. 安装或更新内核
  3. 配置节点
  4. 配置出口
  5. 配置 DNS
  6. 配置分流规则
  7. 应用配置
  8. 验证服务
  9. 显示节点链接
 10. 管理 ACME 证书
 11. 显示导出路径
 12. 显示第三方订阅地址
 13. 备份
 14. 回滚
 15. 升级内核
 16. 卸载代理栈
  0. 退出脚本
EOF
  menu_rule '~'
  printf ' 当前版本: %s   默认目标: %s   Runtime: %s\n' \
    "$(menu_git_version)" \
    "$(menu_env_value DEFAULT_TARGET)" \
    "$(menu_file_status "${OUTPUT_DIR_DEFAULT}/manifest.json")"
  menu_rule '~'
}

show_environment_probe() {
  menu_show_banner
  menu_show_overview
  menu_show_targets
  menu_show_nodes
  menu_show_policy
  menu_show_runtime
  menu_rule '~'
}

menu_show_dns_detail() {
  local lines summary
  mapfile -t lines < <(menu_collect_dns)
  summary="${lines[0]#SUMMARY=}"

  menu_show_banner
  printf '%b\n' "$(menu_color "${MENU_BOLD}" ' DNS 配置详情')"
  printf ' 摘要: %s\n' "${summary}"
  local line
  for line in "${lines[@]:1}"; do
    IFS=$'\t' read -r id type address <<<"${line}"
    printf ' - %-12s %-8s %s\n' "${id}" "${type}" "${address}"
  done
  menu_rule '~'
}

menu_show_routing_detail() {
  local lines summary
  mapfile -t lines < <(menu_collect_routing)
  summary="${lines[0]#SUMMARY=}"

  menu_show_banner
  printf '%b\n' "$(menu_color "${MENU_BOLD}" ' 分流规则详情')"
  printf ' 摘要: %s\n' "${summary}"
  local line
  for line in "${lines[@]:1}"; do
    IFS=$'\t' read -r id label outbound <<<"${line}"
    printf ' - %-16s %-24s -> %s\n' "${id}" "${label}" "${outbound}"
  done
  menu_rule '~'
}

menu_show_outbound_detail() {
  local lines summary
  mapfile -t lines < <(menu_collect_outbounds)
  summary="${lines[0]#SUMMARY=}"

  menu_show_banner
  printf '%b\n' "$(menu_color "${MENU_BOLD}" ' 出口矩阵详情')"
  printf ' 摘要: %s\n' "${summary}"
  local line
  for line in "${lines[@]:1}"; do
    IFS=$'\t' read -r field1 field2 field3 field4 field5 <<<"${line}"
    if [[ "${field1}" == "GROUP" ]]; then
      printf ' - 分组 %-18s 类型 %-10s 成员 %s\n' "${field2}" "${field3}" "${field4}"
    else
      printf ' - %-16s 角色 %-22s 类型 %-8s 栈 %-6s 服务端 %s\n' \
        "${field1}" "${field2}" "${field3}" "${field4}" "${field5}"
    fi
  done
  menu_rule '~'
}

menu_not_implemented() {
  local cmd="$1"
  if type -t not_implemented >/dev/null 2>&1; then
    not_implemented "${cmd}"
  else
    warn "Command '${cmd}' is scaffolded but not implemented yet."
  fi
}

node_menu_render() {
  menu_show_banner
  printf '%b\n' "$(menu_color "${MENU_BOLD}" ' 节点菜单')"
  cat <<'EOF'
  1. 查看当前节点矩阵
  2. 一键添加 VLESS-REALITY
  3. 一键添加 Shadowsocks 2022
  4. 一键添加 VMess-TCP
  5. 一键添加 VMess-mKCP
  6. 一键添加 VMess-WS-TLS
  7. 一键添加 VMess-gRPC-TLS
  8. 一键添加 VLESS-WS-TLS
  9. 一键添加 VLESS-gRPC-TLS
 10. 一键添加 VLESS-XHTTP-TLS
 11. 一键添加 Trojan-WS-TLS
 12. 一键添加 Trojan-gRPC-TLS
 13. 一键添加 VMess-TCP 动态端口
 14. 一键添加 VMess-mKCP 动态端口
 15. 添加 hy2-main
 16. 添加 tuic-alt
 17. 启用或禁用节点
 18. 修改节点端口
 19. 重新生成 UUID / 密钥
 20. 删除节点
  0. 返回上级
EOF
  menu_rule '~'
}

node_menu() {
  if [[ ! -t 0 ]] || [[ ! -t 1 ]]; then
    node_menu_render
    return 0
  fi

  while true; do
    menu_clear
    node_menu_render
    read -r -p '请输入数字【0-20】: ' choice
    case "${choice}" in
      1)
        menu_clear
        menu_show_banner
        menu_show_nodes
        menu_pause
        ;;
      2|3|4|5|6|7|8|9|10|11|12|13|14|15|16)
        local preset target host id port path sni reality_target_host service_name
        case "${choice}" in
          2) preset='reality-main'; port='443' ;;
          3) preset='ss2022-main'; port='24444' ;;
          4) preset='vmess-tcp'; port='20080' ;;
          5) preset='vmess-mkcp'; port='20081' ;;
          6) preset='vmess-ws-tls'; port='8445' ;;
          7) preset='vmess-grpc-tls'; port='9445' ;;
          8) preset='vless-ws-tls'; port='8444' ;;
          9) preset='vless-grpc-tls'; port='9444' ;;
          10) preset='vless-xhttp-tls'; port='10443' ;;
          11) preset='trojan-ws-tls'; port='10444' ;;
          12) preset='trojan-grpc-tls'; port='11443' ;;
          13) preset='vmess-tcp-dynamic'; port='20000-20100' ;;
          14) preset='vmess-mkcp-dynamic'; port='20101-20200' ;;
          15) preset='hy2-main'; port='443' ;;
          16) preset='tuic-alt'; port='8443' ;;
        esac
        target="$(menu_prompt_required '目标主机 ID' "$(menu_env_value DEFAULT_TARGET)")"
        host="$(menu_prompt_required '接入域名 / Host' 'edge.example.com')"
        id="$(menu_prompt_required '节点 ID' "${preset}-${target}")"
        port="$(menu_prompt_required '监听端口' "${port}")"
        if [[ "${preset}" == 'reality-main' ]]; then
          reality_target_host="$(menu_prompt_required 'REALITY 伪装域名' 'www.microsoft.com')"
          run_node_add_preset \
            --preset "${preset}" \
            --target "${target}" \
            --host "${host}" \
            --id "${id}" \
            --port "${port}" \
            --reality-target-host "${reality_target_host}"
        elif [[ "${preset}" == 'vless-ws-tls' || "${preset}" == 'vmess-ws-tls' || "${preset}" == 'trojan-ws-tls' ]]; then
          sni="$(menu_prompt_required 'SNI' "${host}")"
          path="$(menu_prompt_required 'WS Path' "/$(printf '%s' "${preset}" | tr -cd 'a-z0-9-')")"
          run_node_add_preset \
            --preset "${preset}" \
            --target "${target}" \
            --host "${host}" \
            --id "${id}" \
            --port "${port}" \
            --sni "${sni}" \
            --path "${path}"
        elif [[ "${preset}" == 'vless-grpc-tls' || "${preset}" == 'vmess-grpc-tls' || "${preset}" == 'trojan-grpc-tls' ]]; then
          sni="$(menu_prompt_required 'SNI' "${host}")"
          service_name="$(menu_prompt_required 'gRPC Service Name' "grpc-$(date +%H%M%S)")"
          run_node_add_preset \
            --preset "${preset}" \
            --target "${target}" \
            --host "${host}" \
            --id "${id}" \
            --port "${port}" \
            --sni "${sni}" \
            --service-name "${service_name}"
        elif [[ "${preset}" == 'vless-xhttp-tls' ]]; then
          sni="$(menu_prompt_required 'SNI' "${host}")"
          path="$(menu_prompt_required 'XHTTP Path' '/xhttp')"
          run_node_add_preset \
            --preset "${preset}" \
            --target "${target}" \
            --host "${host}" \
            --id "${id}" \
            --port "${port}" \
            --sni "${sni}" \
            --path "${path}"
        else
          sni="$(menu_prompt_required 'SNI' "${host}")"
          if [[ "${preset}" == 'hy2-main' || "${preset}" == 'tuic-alt' ]]; then
            run_node_add_preset \
              --preset "${preset}" \
              --target "${target}" \
              --host "${host}" \
              --id "${id}" \
              --port "${port}" \
              --sni "${sni}"
          else
            run_node_add_preset \
              --preset "${preset}" \
              --target "${target}" \
              --host "${host}" \
              --id "${id}" \
              --port "${port}"
          fi
        fi
        menu_pause
        ;;
      17)
        local id enabled
        id="$(menu_prompt_required '节点 ID')"
        enabled="$(menu_prompt_bool '是否启用' 'true')"
        run_node_toggle --id "${id}" --enabled "${enabled}"
        menu_pause
        ;;
      18)
        local id port
        id="$(menu_prompt_required '节点 ID')"
        port="$(menu_prompt_required '新的端口')"
        run_node_set_port --id "${id}" --port "${port}"
        menu_pause
        ;;
      19)
        local id
        id="$(menu_prompt_required '节点 ID')"
        run_node_rotate_secret --id "${id}"
        menu_pause
        ;;
      20)
        local id
        id="$(menu_prompt_required '节点 ID')"
        run_node_delete --id "${id}"
        menu_pause
        ;;
      0) return 0 ;;
      *) warn '无效输入，请重新选择。'; menu_pause ;;
    esac
  done
}

outbound_menu_render() {
  menu_show_banner
  printf '%b\n' "$(menu_color "${MENU_BOLD}" ' 出口菜单')"
  cat <<'EOF'
  1. 查看出口矩阵
  2. 添加静态住宅 SOCKS5
  3. 添加动态住宅
  4. 启用或禁用出口
  5. 修改出口服务器与端口
  6. 修改出口账号密码
  7. 配置 residential-auto 分组
  8. 删除出口
  9. 导出当前出口详情
  0. 返回上级
EOF
  menu_rule '~'
}

outbound_menu() {
  if [[ ! -t 0 ]] || [[ ! -t 1 ]]; then
    outbound_menu_render
    return 0
  fi

  while true; do
    menu_clear
    outbound_menu_render
    read -r -p '请输入数字【0-9】: ' choice
    case "${choice}" in
      1)
        menu_clear
        menu_show_outbound_detail
        menu_pause
        ;;
      2|3)
        local role id server port user pass stack enabled
        role=$([[ "${choice}" == '2' ]] && printf 'residential-static' || printf 'residential-dynamic')
        id="$(menu_prompt_required '出口 ID' "$([[ "${choice}" == '2' ]] && printf 'res-us-static-2' || printf 'res-us-dyn-2')")"
        server="$(menu_prompt_required 'SOCKS5 服务器')"
        port="$(menu_prompt_required 'SOCKS5 端口')"
        user="$(menu_prompt_required '用户名')"
        pass="$(menu_prompt_required '密码')"
        stack="$(menu_prompt_required '协议栈 (dual/ipv4/ipv6)' 'dual')"
        enabled="$(menu_prompt_bool '立即启用' 'true')"
        run_outbound_add_socks5 \
          --id "${id}" \
          --role "${role}" \
          --server "${server}" \
          --port "${port}" \
          --user "${user}" \
          --pass "${pass}" \
          --stack "${stack}" \
          --enabled "${enabled}"
        menu_pause
        ;;
      4)
        local id enabled
        id="$(menu_prompt_required '出口 ID')"
        enabled="$(menu_prompt_bool '是否启用' 'true')"
        run_outbound_toggle --id "${id}" --enabled "${enabled}"
        menu_pause
        ;;
      5)
        local id server port
        id="$(menu_prompt_required '出口 ID')"
        server="$(menu_prompt_required '新的服务器')"
        port="$(menu_prompt_required '新的端口')"
        run_outbound_set_server --id "${id}" --server "${server}" --port "${port}"
        menu_pause
        ;;
      6)
        local id user pass
        id="$(menu_prompt_required '出口 ID')"
        user="$(menu_prompt_required '新的用户名')"
        pass="$(menu_prompt_required '新的密码')"
        run_outbound_set_credentials --id "${id}" --user "${user}" --pass "${pass}"
        menu_pause
        ;;
      7)
        local members
        members="$(menu_prompt_required 'residential-auto 成员，逗号分隔' 'res-us-static,res-us-dyn-1')"
        run_outbound_group_set --id residential-auto --members "${members}"
        menu_pause
        ;;
      8)
        local id
        id="$(menu_prompt_required '出口 ID')"
        run_outbound_delete --id "${id}"
        menu_pause
        ;;
      9)
        menu_clear
        menu_show_outbound_detail
        menu_pause
        ;;
      0) return 0 ;;
      *) warn '无效输入，请重新选择。'; menu_pause ;;
    esac
  done
}

dns_menu_render() {
  menu_show_banner
  printf '%b\n' "$(menu_color "${MENU_BOLD}" ' DNS 菜单')"
  cat <<'EOF'
  1. 查看 DNS 配置
  2. 修改全局默认 DNS
  3. 添加 DNS 服务器
  0. 返回上级
EOF
  menu_rule '~'
}

dns_menu() {
  if [[ ! -t 0 ]] || [[ ! -t 1 ]]; then
    dns_menu_render
    return 0
  fi

  while true; do
    menu_clear
    dns_menu_render
    read -r -p '请输入数字【0-3】: ' choice
    case "${choice}" in
      1)
        menu_clear
        menu_show_dns_detail
        menu_pause
        ;;
      2)
        local server
        server="$(menu_prompt_required '新的全局 DNS 服务器 ID' 'dns-main')"
        run_dns_set_global --server "${server}"
        menu_pause
        ;;
      3)
        local id type address
        id="$(menu_prompt_required 'DNS 服务器 ID')"
        type="$(menu_prompt_required '类型 (doh/udp/tls)' 'doh')"
        address="$(menu_prompt_required '地址')"
        run_dns_add_server --id "${id}" --type "${type}" --address "${address}"
        menu_pause
        ;;
      0) return 0 ;;
      *) warn '无效输入，请重新选择。'; menu_pause ;;
    esac
  done
}

routing_menu_render() {
  menu_show_banner
  printf '%b\n' "$(menu_color "${MENU_BOLD}" ' 分流菜单')"
  cat <<'EOF'
  1. 查看分流规则
  2. 修改默认出口
  3. 开关 BT 阻断
  4. 开关 UDP/443 阻断
  0. 返回上级
EOF
  menu_rule '~'
}

routing_menu() {
  if [[ ! -t 0 ]] || [[ ! -t 1 ]]; then
    routing_menu_render
    return 0
  fi

  while true; do
    menu_clear
    routing_menu_render
    read -r -p '请输入数字【0-4】: ' choice
    case "${choice}" in
      1)
        menu_clear
        menu_show_routing_detail
        menu_pause
        ;;
      2)
        local outbound
        outbound="$(menu_prompt_required '新的默认出口' 'direct')"
        run_route_set_final --outbound "${outbound}"
        menu_pause
        ;;
      3)
        local enabled
        enabled="$(menu_prompt_bool '是否启用 BT 阻断' 'true')"
        run_route_toggle_default --field block_bittorrent --enabled "${enabled}"
        menu_pause
        ;;
      4)
        local enabled
        enabled="$(menu_prompt_bool '是否启用 UDP/443 阻断' 'false')"
        run_route_toggle_default --field block_udp_443 --enabled "${enabled}"
        menu_pause
        ;;
      0) return 0 ;;
      *) warn '无效输入，请重新选择。'; menu_pause ;;
    esac
  done
}

uninstall_menu_render() {
  menu_show_banner
  printf '%b\n' "$(menu_color "${MENU_BOLD}" ' 卸载菜单')"
  cat <<'EOF'
  1. 卸载当前脚本部署的 xray
  2. 卸载当前脚本部署的 sing-box
  3. 卸载当前脚本部署的 cloudflared
  4. 删除当前脚本生成的配置与导出
  5. 恢复到上一个成功快照
  6. 查看保留资源说明
  0. 返回上级
EOF
  menu_rule '-'
  printf ' 保护约束: 1 号机的 sub2api / caddy / 80 / 443 / 8080 / /root/sub2api-deploy 均不得误删\n'
  menu_rule '~'
}

uninstall_menu() {
  if [[ ! -t 0 ]] || [[ ! -t 1 ]]; then
    uninstall_menu_render
    return 0
  fi

  while true; do
    menu_clear
    uninstall_menu_render
    read -r -p '请输入数字【0-6】: ' choice
    case "${choice}" in
      1) run_uninstall xray --target "$(menu_env_value DEFAULT_TARGET)"; menu_pause ;;
      2) run_uninstall sing-box --target "$(menu_env_value DEFAULT_TARGET)"; menu_pause ;;
      3) run_uninstall cloudflared --target "$(menu_env_value DEFAULT_TARGET)"; menu_pause ;;
      4) run_uninstall generated --target "$(menu_env_value DEFAULT_TARGET)"; menu_pause ;;
      5) run_remote_snapshot_rollback --target "$(menu_env_value DEFAULT_TARGET)"; menu_pause ;;
      6)
        menu_clear
        menu_show_banner
        menu_show_targets
        menu_pause
        ;;
      0) return 0 ;;
      *) warn '无效输入，请重新选择。'; menu_pause ;;
    esac
  done
}

cert_menu_render() {
  menu_show_banner
  printf '%b\n' "$(menu_color "${MENU_BOLD}" ' ACME 证书管理')"
  cat <<'EOF'
  1. 查看当前 ACME 计划
  2. 查看远端证书状态
  3. 执行证书签发
  4. 执行证书续期
  0. 返回上级
EOF
  menu_rule '-'
  printf ' 当前目标: %s\n' "$(menu_env_value DEFAULT_TARGET)"
  printf ' ACME 计划: %s\n' "$(menu_file_status "${OUTPUT_DIR_DEFAULT}/acme-plan.json")"
  menu_rule '~'
}

cert_menu() {
  if [[ ! -t 0 ]] || [[ ! -t 1 ]]; then
    cert_menu_render
    return 0
  fi

  while true; do
    menu_clear
    cert_menu_render
    read -r -p '请输入数字【0-4】: ' choice
    case "${choice}" in
      1)
        menu_clear
        show_cert_plan
        menu_pause
        ;;
      2)
        menu_clear
        show_cert_status
        menu_pause
        ;;
      3)
        run_cert_issue
        menu_pause
        ;;
      4)
        run_cert_renew
        menu_pause
        ;;
      0) return 0 ;;
      *) warn '无效输入，请重新选择。'; menu_pause ;;
    esac
  done
}

main_menu_render() {
  menu_show_banner
  menu_show_home_actions
  menu_show_script_info
  menu_show_server_info
  menu_show_core_versions
  menu_show_runtime_status
  menu_rule '~'
}

versions_menu_render() {
  menu_show_banner
  printf '%b\n' "$(menu_color "${MENU_BOLD}" ' 版本与升级')"
  cat <<'EOF'
  1. 查看 FGFW 脚本版本
  2. 查看 Core 版本
  3. 检查脚本更新
  4. 升级 FGFW 脚本
  5. 检查 Core 更新
  6. 升级 Core
  7. 查看最近升级记录
  0. 返回上级
EOF
  menu_rule '~'
}

versions_menu() {
  if [[ ! -t 0 ]] || [[ ! -t 1 ]]; then
    versions_menu_render
    return 0
  fi

  while true; do
    menu_clear
    versions_menu_render
    read -r -p '请输入数字【0-7】: ' choice
    case "${choice}" in
      1|2)
        menu_show_version_overview
        menu_pause
        ;;
      3)
        menu_check_script_update
        menu_pause
        ;;
      4)
        menu_upgrade_script
        menu_pause
        ;;
      5)
        menu_show_version_overview
        menu_pause
        ;;
      6)
        run_upgrade --target "$(menu_env_value DEFAULT_TARGET)"
        menu_pause
        ;;
      7)
        menu_clear
        menu_show_upgrade_history
        menu_pause
        ;;
      0) return 0 ;;
      *) warn '无效输入，请重新选择。'; menu_pause ;;
    esac
  done
}

service_menu_render() {
  menu_show_banner
  printf '%b\n' "$(menu_color "${MENU_BOLD}" ' 服务启停')"
  cat <<'EOF'
  1. 启动核心服务
  2. 停止核心服务
  3. 重启核心服务
  4. 启用开机自启
  5. 关闭开机自启
  6. 查看服务状态
  0. 返回上级
EOF
  menu_rule '~'
}

service_menu() {
  if [[ ! -t 0 ]] || [[ ! -t 1 ]]; then
    service_menu_render
    return 0
  fi

  while true; do
    menu_clear
    service_menu_render
    read -r -p '请输入数字【0-6】: ' choice
    case "${choice}" in
      1) run_service_action start --target "$(menu_env_value DEFAULT_TARGET)" xray sing-box; menu_pause ;;
      2) run_service_action stop --target "$(menu_env_value DEFAULT_TARGET)" xray sing-box; menu_pause ;;
      3) run_service_action restart --target "$(menu_env_value DEFAULT_TARGET)" xray sing-box; menu_pause ;;
      4) run_service_action enable --target "$(menu_env_value DEFAULT_TARGET)" xray sing-box; menu_pause ;;
      5) run_service_action disable --target "$(menu_env_value DEFAULT_TARGET)" xray sing-box; menu_pause ;;
      6)
        menu_clear
        run_service_action status --target "$(menu_env_value DEFAULT_TARGET)" xray sing-box cloudflared
        menu_pause
        ;;
      0) return 0 ;;
      *) warn '无效输入，请重新选择。'; menu_pause ;;
    esac
  done
}

first_deploy_menu_render() {
  menu_show_banner
  printf '%b\n' "$(menu_color "${MENU_BOLD}" ' 首次部署')"
  cat <<'EOF'
  1. 环境检测
  2. 配置节点矩阵
  3. 配置出口
  4. 配置 DNS
  5. 配置分流
  6. 证书管理
  7. 安装并应用
  8. 导出并验证
  0. 返回首页
EOF
  menu_rule '~'
}

first_deploy_menu() {
  if [[ ! -t 0 ]] || [[ ! -t 1 ]]; then
    first_deploy_menu_render
    return 0
  fi

  while true; do
    menu_clear
    first_deploy_menu_render
    read -r -p '请输入数字【0-8】: ' choice
    case "${choice}" in
      1) menu_clear; show_environment_probe; menu_pause ;;
      2) node_menu ;;
      3) outbound_menu ;;
      4) dns_menu ;;
      5) routing_menu ;;
      6) cert_menu ;;
      7) run_apply --target "$(menu_env_value DEFAULT_TARGET)"; menu_pause ;;
      8)
        run_validation
        render_artifacts
        show_export_paths
        menu_pause
        ;;
      0) return 0 ;;
      *) warn '无效输入，请重新选择。'; menu_pause ;;
    esac
  done
}

daily_ops_menu_render() {
  menu_show_banner
  printf '%b\n' "$(menu_color "${MENU_BOLD}" ' 日常运维')"
  cat <<'EOF'
  1. 版本与升级
  2. 重启服务
  3. 备份
  4. 回滚
  5. 服务启停
  0. 返回首页
EOF
  menu_rule '~'
}

daily_ops_menu() {
  if [[ ! -t 0 ]] || [[ ! -t 1 ]]; then
    daily_ops_menu_render
    return 0
  fi

  while true; do
    menu_clear
    daily_ops_menu_render
    read -r -p '请输入数字【0-5】: ' choice
    case "${choice}" in
      1) versions_menu ;;
      2) run_restart --target "$(menu_env_value DEFAULT_TARGET)" xray sing-box; menu_pause ;;
      3) run_backup; menu_pause ;;
      4) run_rollback; menu_pause ;;
      5) service_menu ;;
      0) return 0 ;;
      *) warn '无效输入，请重新选择。'; menu_pause ;;
    esac
  done
}

export_menu_render() {
  menu_show_banner
  printf '%b\n' "$(menu_color "${MENU_BOLD}" ' 导出分享')"
  cat <<'EOF'
  1. 重建导出产物
  2. 显示节点链接
  3. 显示导出路径
  4. 显示订阅地址
  5. 查看节点说明
  0. 返回首页
EOF
  menu_rule '~'
}

export_menu() {
  if [[ ! -t 0 ]] || [[ ! -t 1 ]]; then
    export_menu_render
    return 0
  fi

  while true; do
    menu_clear
    export_menu_render
    read -r -p '请输入数字【0-5】: ' choice
    case "${choice}" in
      1) run_validation; render_artifacts; show_export_paths; menu_pause ;;
      2) show_links; menu_pause ;;
      3) show_export_paths; menu_pause ;;
      4) show_sub_url; menu_pause ;;
      5)
        if [[ -f "${PROJECT_ROOT}/node-notes.md" ]]; then
          cat "${PROJECT_ROOT}/node-notes.md"
        else
          warn 'node-notes.md 不存在'
        fi
        menu_pause
        ;;
      0) return 0 ;;
      *) warn '无效输入，请重新选择。'; menu_pause ;;
    esac
  done
}

advanced_menu_render() {
  menu_show_banner
  printf '%b\n' "$(menu_color "${MENU_BOLD}" ' 高级配置')"
  cat <<'EOF'
  1. 节点配置
  2. 出口配置
  3. DNS 配置
  4. 分流规则
  5. 卸载与清理
  0. 返回首页
EOF
  menu_rule '~'
}

advanced_menu() {
  if [[ ! -t 0 ]] || [[ ! -t 1 ]]; then
    advanced_menu_render
    return 0
  fi

  while true; do
    menu_clear
    advanced_menu_render
    read -r -p '请输入数字【0-5】: ' choice
    case "${choice}" in
      1) node_menu ;;
      2) outbound_menu ;;
      3) dns_menu ;;
      4) routing_menu ;;
      5) uninstall_menu ;;
      0) return 0 ;;
      *) warn '无效输入，请重新选择。'; menu_pause ;;
    esac
  done
}

troubleshoot_menu_render() {
  menu_show_banner
  printf '%b\n' "$(menu_color "${MENU_BOLD}" ' 故障排查')"
  cat <<'EOF'
  1. 运行诊断
  2. 校验配置
  3. 校验服务
  4. 查看日志
  5. 查看渲染摘要
  0. 返回首页
EOF
  menu_rule '~'
}

troubleshoot_menu() {
  if [[ ! -t 0 ]] || [[ ! -t 1 ]]; then
    troubleshoot_menu_render
    return 0
  fi

  while true; do
    menu_clear
    troubleshoot_menu_render
    read -r -p '请输入数字【0-5】: ' choice
    case "${choice}" in
      1)
        menu_clear
        show_environment_probe
        menu_pause
        ;;
      2)
        run_validation
        menu_pause
        ;;
      3)
        menu_clear
        run_service_action status --target "$(menu_env_value DEFAULT_TARGET)" xray sing-box cloudflared
        menu_pause
        ;;
      4)
        menu_clear
        menu_show_recent_logs
        menu_pause
        ;;
      5)
        menu_clear
        menu_show_banner
        menu_show_nodes
        menu_show_policy
        menu_show_runtime
        menu_pause
        ;;
      0) return 0 ;;
      *) warn '无效输入，请重新选择。'; menu_pause ;;
    esac
  done
}

main_menu_handle() {
  local choice="$1"
  case "${choice}" in
    1) first_deploy_menu ;;
    2) daily_ops_menu ;;
    3) export_menu ;;
    4) advanced_menu ;;
    5) troubleshoot_menu ;;
    0) return 1 ;;
    *)
      warn '无效输入，请重新选择。'
      menu_pause
      ;;
  esac
  return 0
}

main_menu() {
  if [[ ! -t 0 ]] || [[ ! -t 1 ]]; then
    main_menu_render
    return 0
  fi

  while true; do
    menu_clear
    main_menu_render
    read -r -p '请输入数字【0-5】: ' choice
    if ! main_menu_handle "${choice}"; then
      break
    fi
  done
}
