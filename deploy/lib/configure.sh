#!/usr/bin/env bash

config_tool() {
  local secrets_file
  secrets_file="$(resolve_secrets_file)"
  ruby "${SCRIPT_DIR}/lib/config_tool.rb" "${CONFIG_DIR}" "${secrets_file}" "$@"
}

refresh_after_config_change() {
  run_validation
  render_artifacts
}

run_node_add_preset() {
  config_tool node-add "$@"
  refresh_after_config_change
}

run_node_toggle() {
  config_tool node-toggle "$@"
  refresh_after_config_change
}

run_node_set_port() {
  config_tool node-set-port "$@"
  refresh_after_config_change
}

run_node_rotate_secret() {
  config_tool node-rotate-secret "$@"
  refresh_after_config_change
}

run_node_delete() {
  config_tool node-delete "$@"
  refresh_after_config_change
}

run_outbound_add_socks5() {
  config_tool outbound-add-socks5 "$@"
  refresh_after_config_change
}

run_outbound_toggle() {
  config_tool outbound-toggle "$@"
  refresh_after_config_change
}

run_outbound_set_server() {
  config_tool outbound-set-server "$@"
  refresh_after_config_change
}

run_outbound_set_credentials() {
  config_tool outbound-set-credentials "$@"
  refresh_after_config_change
}

run_outbound_group_set() {
  config_tool outbound-group-set "$@"
  refresh_after_config_change
}

run_outbound_delete() {
  config_tool outbound-delete "$@"
  refresh_after_config_change
}

run_dns_set_global() {
  config_tool dns-set-global "$@"
  refresh_after_config_change
}

run_dns_add_server() {
  config_tool dns-add-server "$@"
  refresh_after_config_change
}

run_route_set_final() {
  config_tool route-set-final "$@"
  refresh_after_config_change
}

run_route_toggle_default() {
  config_tool route-toggle-default "$@"
  refresh_after_config_change
}
