#!/usr/bin/env bash

show_export_paths() {
  local file="${CONFIG_DIR}/export.yaml"
  require_file "${file}"
  info "Configured export paths:"
  ruby -e '
    require "yaml"
    config = YAML.safe_load(File.read(ARGV[0]), permitted_classes: [], aliases: false) || {}
    exports = config.fetch("exports", {})
    base = exports["base_dir"] || "-"
    files = exports["files"] || {}
    files.each do |key, value|
      puts format("  %-16s %s/%s", key, base, value)
    end
  ' "${file}"
}

show_sub_url() {
  local file="${CONFIG_DIR}/export.yaml"
  require_file "${file}"
  info "External subscription URL templates:"
  awk -F': ' '
    /^[[:space:]]*- id:/ {
      id=$2
      next
    }
    /^[[:space:]]*template:/ {
      printf "  %-16s %s\n", id, $2
    }
  ' "${file}"
}

show_links() {
  local links_file="${OUTPUT_DIR_DEFAULT}/links.txt"
  if [[ ! -f "${links_file}" ]]; then
    warn "No rendered links yet: ${links_file}"
    return 0
  fi
  cat "${links_file}"
}
