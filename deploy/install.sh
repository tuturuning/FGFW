#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=/dev/null
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/lib/validate.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/lib/render.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/lib/apply.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/lib/acme.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/lib/manage.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/lib/configure.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/lib/menu.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/lib/export.sh"

usage() {
  cat <<'EOF'
Usage:
  ./deploy/install.sh help
  ./deploy/install.sh menu
  ./deploy/install.sh validate
  ./deploy/install.sh render
  ./deploy/install.sh apply [--target <id>] [--skip-start]
  ./deploy/install.sh cert-plan [--target <id>]
  ./deploy/install.sh cert-status [--target <id>]
  ./deploy/install.sh cert-issue [--target <id>]
  ./deploy/install.sh cert-renew [--target <id>]
  ./deploy/install.sh install [--target <id>]
  ./deploy/install.sh restart [--target <id>] [services...]
  ./deploy/install.sh backup
  ./deploy/install.sh rollback [snapshot_dir]
  ./deploy/install.sh upgrade [--target <id>]
  ./deploy/install.sh uninstall [xray|sing-box|cloudflared|generated|all|all-and-certs] [--target <id>]
  ./deploy/install.sh export
  ./deploy/install.sh show-links
  ./deploy/install.sh show-export-paths
  ./deploy/install.sh show-sub-url
  ./deploy/install.sh status
EOF
}

cmd="${1:-help}"
shift || true

case "${cmd}" in
  help|-h|--help)
    usage
    ;;
  menu)
    main_menu
    ;;
  validate)
    run_validation
    ;;
  render)
    run_validation
    render_artifacts
    ;;
  apply)
    run_apply "$@"
    ;;
  cert-plan)
    show_cert_plan "$@"
    ;;
  cert-status)
    show_cert_status "$@"
    ;;
  cert-issue)
    run_cert_issue "$@"
    ;;
  cert-renew)
    run_cert_renew "$@"
    ;;
  export)
    run_validation
    render_artifacts
    show_export_paths
    show_sub_url
    ;;
  show-links)
    show_links
    ;;
  show-export-paths)
    show_export_paths
    ;;
  show-sub-url)
    show_sub_url
    ;;
  status)
    show_status
    ;;
  install)
    run_install "$@"
    ;;
  restart)
    run_restart "$@"
    ;;
  backup)
    run_backup "$@"
    ;;
  rollback)
    run_rollback "$@"
    ;;
  upgrade)
    run_upgrade "$@"
    ;;
  uninstall)
    run_uninstall "$@"
    ;;
  outbound)
    subcmd="${1:-}"
    case "${subcmd}" in
      add)
        shift || true
        run_outbound_add_socks5 "$@"
        ;;
      *)
        die "Unknown outbound subcommand: ${subcmd:-<empty>}"
        ;;
    esac
    ;;
  *)
    die "Unknown command: ${cmd}"
    ;;
esac
