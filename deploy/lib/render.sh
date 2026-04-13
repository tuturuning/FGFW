#!/usr/bin/env bash

render_artifacts() {
  ensure_runtime_dirs

  local secrets_file
  secrets_file="$(resolve_secrets_file)"
  if [[ "${secrets_file}" == "${CONFIG_DIR}/secrets.env.example" ]]; then
    warn "Using example secrets file. Rendered artifacts will contain placeholder values."
  fi

  info "Rendering manifest and export artifacts..."
  ruby "${SCRIPT_DIR}/lib/render_manifest.rb" \
    "${CONFIG_DIR}" \
    "${OUTPUT_DIR_DEFAULT}" \
    "${secrets_file}"
  ruby "${SCRIPT_DIR}/lib/render_runtime_configs.rb" \
    "${OUTPUT_DIR_DEFAULT}/manifest.json" \
    "${RUNTIME_CONFIG_DIR_DEFAULT}" \
    "${PROJECT_ROOT}/deploy/domains"
  ruby "${SCRIPT_DIR}/lib/render_services.rb" \
    "${CONFIG_DIR}/app.env.example" \
    "${PROJECT_ROOT}/deploy/templates/services" \
    "${RUNTIME_SYSTEMD_DIR_DEFAULT}"
  info "Rendered artifacts into ${OUTPUT_DIR_DEFAULT}"
}
