#!/usr/bin/env bash
#
# universal-migrate-site-script
# Pull a WordPress or Laravel site (files + database) from a remote server down
# to the machine this script runs on, then make it work on a local domain.
#
#   ./migrate.sh --help
#
# Works on bash 3.2+ (macOS default) and bash 5 (Linux). Primary target is a
# Linux host/container; see README.md.

set -o pipefail
set -u

VERSION="1.1.0"
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)

# shellcheck source=lib/util.sh
. "$SCRIPT_DIR/lib/util.sh"
# shellcheck source=lib/ui.sh
. "$SCRIPT_DIR/lib/ui.sh"
# shellcheck source=lib/env.sh
. "$SCRIPT_DIR/lib/env.sh"
# shellcheck source=lib/ssh.sh
. "$SCRIPT_DIR/lib/ssh.sh"
# shellcheck source=lib/db.sh
. "$SCRIPT_DIR/lib/db.sh"
# shellcheck source=lib/wp.sh
. "$SCRIPT_DIR/lib/wp.sh"
# shellcheck source=lib/runner.sh
. "$SCRIPT_DIR/lib/runner.sh"
# shellcheck source=lib/preflight.sh
. "$SCRIPT_DIR/lib/preflight.sh"
# shellcheck source=steps/clear-web-root.sh
. "$SCRIPT_DIR/steps/clear-web-root.sh"
# shellcheck source=steps/maintenance.sh
. "$SCRIPT_DIR/steps/maintenance.sh"
# shellcheck source=steps/sync-files.sh
. "$SCRIPT_DIR/steps/sync-files.sh"
# shellcheck source=steps/migrate-db.sh
. "$SCRIPT_DIR/steps/migrate-db.sh"
# shellcheck source=steps/app-config.sh
. "$SCRIPT_DIR/steps/app-config.sh"
# shellcheck source=steps/host-cleanup.sh
. "$SCRIPT_DIR/steps/host-cleanup.sh"
# shellcheck source=steps/kinsta-plugins.sh
. "$SCRIPT_DIR/steps/kinsta-plugins.sh"
# shellcheck source=steps/local-hardening.sh
. "$SCRIPT_DIR/steps/local-hardening.sh"
# shellcheck source=steps/cache-refresh.sh
. "$SCRIPT_DIR/steps/cache-refresh.sh"
# shellcheck source=steps/verify.sh
. "$SCRIPT_DIR/steps/verify.sh"

# ----------------------------------------------------------------- run state
ENV_FILE="$SCRIPT_DIR/.env"
AUTO_CONFIRM=false
DRY_RUN=false
CHECK_ONLY=false
LIST_STEPS=false
CLI_PLAIN=false
CLI_AUTO=false
SKIP_STEPS=""
ONLY_STEPS=""
WITH_STEPS=""
RUN_START=$SECONDS
RUN_TAG=""
TMP_DIR=""
LOG_FILE=""
REPORT_FILE=""
MAINT_ACTIVE=false
WEB_ROOT_CLEARED=false
REMOTE=""

usage() {
  cat <<'USAGE'
Usage: ./migrate.sh [options]

Pull a WordPress or Laravel site (files + database) from a remote server to
this machine. Configuration lives in .env (see .env.example).

Options:
  -e, --env FILE      Env file to load (default: ./.env)
  -y, --yes           Unattended: run every enabled step without prompting
  -n, --dry-run       Show what would happen; change no files, DB or config
  -c, --check         Run the preflight checks (incl. disk space) and exit
      --skip IDS      Comma-separated step ids to skip (repeatable)
      --only IDS      Run only these step ids (repeatable)
      --with IDS      Enable opt-in steps, e.g. clear-web-root, kinsta-plugins
      --plain         No colours or emoji (CI-friendly output)
      --list-steps    Print the step ids and exit
  -V, --version       Print the version
  -h, --help          This help

.env equivalents: auto_confirm, plain_output, skip_<step>, run_<step>.
USAGE
}

parse_args() {
  while (($#)); do
    case $1 in
      -e|--env) [[ $# -ge 2 ]] || die "--env needs a file argument"; ENV_FILE=$2; shift 2 ;;
      --env=*) ENV_FILE=${1#*=}; shift ;;
      -y|--yes) CLI_AUTO=true; shift ;;
      -n|--dry-run) DRY_RUN=true; shift ;;
      -c|--check) CHECK_ONLY=true; shift ;;
      --skip) [[ $# -ge 2 ]] || die "--skip needs step ids"; SKIP_STEPS="${SKIP_STEPS:+$SKIP_STEPS,}$2"; shift 2 ;;
      --skip=*) SKIP_STEPS="${SKIP_STEPS:+$SKIP_STEPS,}${1#*=}"; shift ;;
      --only) [[ $# -ge 2 ]] || die "--only needs step ids"; ONLY_STEPS="${ONLY_STEPS:+$ONLY_STEPS,}$2"; shift 2 ;;
      --only=*) ONLY_STEPS="${ONLY_STEPS:+$ONLY_STEPS,}${1#*=}"; shift ;;
      --with) [[ $# -ge 2 ]] || die "--with needs step ids"; WITH_STEPS="${WITH_STEPS:+$WITH_STEPS,}$2"; shift 2 ;;
      --with=*) WITH_STEPS="${WITH_STEPS:+$WITH_STEPS,}${1#*=}"; shift ;;
      --plain) CLI_PLAIN=true; shift ;;
      --list-steps) LIST_STEPS=true; shift ;;
      -V|--version) printf 'universal-migrate-site-script %s\n' "$VERSION"; exit 0 ;;
      -h|--help) usage; exit 0 ;;
      *) printf 'Unknown option: %s (see --help)\n' "$1" >&2; exit 2 ;;
    esac
  done
  [[ $ENV_FILE == /* ]] || ENV_FILE="$PWD/$ENV_FILE"
}

register_steps() {
  #             id               title                                        function              platforms          default
  register_step clear-web-root  "Clear local web root"                        step_clear_web_root   all                n "Delete everything inside local_web_root before a full sync"
  register_step maintenance-on  "Enable maintenance mode (local site)"        step_maintenance_on   wordpress,laravel  y "Write .maintenance / artisan down so visitors see a notice during the sync"
  register_step sync-files      "Sync files from remote"                      step_sync_files       all                y "rsync the remote web root into local_web_root"
  register_step migrate-db      "Migrate database"                            step_migrate_db       all                y "Export the remote DB, back up the local DB, drop and re-import"
  register_step app-config      "Update app config and URLs"                  step_app_config       wordpress,laravel  y "Local DB credentials, WP_HOME/WP_SITEURL + search-replace, or Laravel .env"
  register_step host-cleanup    "Remove WP Engine config and host drop-ins"   step_host_cleanup     wordpress          y "Strip WPE lines from wp-config.php, host mu-plugins and cache drop-ins"
  register_step kinsta-plugins  "Install Kinsta MU plugins"                   step_kinsta_plugins   wordpress          n "Only when the destination is Kinsta"
  register_step local-hardening "Apply local WordPress settings"              step_local_hardening  wordpress          y "WP_ENVIRONMENT_TYPE, WP_DEBUG, noindex, host plugins off, optional admin user"
  register_step cache-refresh   "Flush caches and permalinks"                 step_cache_refresh    wordpress,laravel  y "wp rewrite/cache flush or artisan optimize:clear"
  register_step verify          "Verify the migrated site"                    step_verify           all                y "Site loads, URLs updated, table counts, HTTP check"
  register_step maintenance-off "Disable maintenance mode (local site)"       step_maintenance_off  wordpress,laravel  y "Remove .maintenance / artisan up"
}

validate_step_lists() {
  local list id
  for list in "$SKIP_STEPS" "$ONLY_STEPS" "$WITH_STEPS"; do
    [[ -n $list ]] || continue
    local IFS=,
    for id in $list; do
      step_index "$id" >/dev/null || die "Unknown step id '${id}'. Run ./migrate.sh --list-steps"
    done
  done
}

strip_ansi() {
  local esc
  esc=$(printf '\033')
  sed -E "s/${esc}\[[0-9;]*[A-Za-z]//g; s/${esc}\(B//g"
}

setup_logging() {
  mkdir -p "$log_dir" "$dump_dir" || die "Cannot create ${log_dir} or ${dump_dir}"
  RUN_TAG=$(now_tag)
  LOG_FILE="$log_dir/migrate-${RUN_TAG}.log"
  REPORT_FILE="$log_dir/migrate-report-${RUN_TAG}.txt"
  # Mirror everything to the log file with colour codes stripped.
  exec > >(tee >(strip_ansi >> "$LOG_FILE")) 2>&1
}

cleanup() {
  local rc=$?
  [[ ${TUNNEL_OPEN:-false} == true ]] && close_tunnel
  if [[ $MAINT_ACTIVE == true ]]; then
    warn "Maintenance mode is still ACTIVE for ${local_web_root}. Remove .maintenance (WordPress) or run 'php artisan up' (Laravel) when ready."
  fi
  [[ -n $TMP_DIR && -d $TMP_DIR ]] && rm -rf "$TMP_DIR"
  sleep 0.2 2>/dev/null || true
  exit "$rc"
}

print_banner() {
  local i reason state mode
  mode=interactive
  is_true "$AUTO_CONFIRM" && mode=unattended
  is_dry_run && mode="${mode}, DRY RUN"
  printf '\n%s%suniversal-migrate-site-script v%s%s\n' "$C_BOLD" "$C_MAGENTA" "$VERSION" "$C_RESET"
  hr
  printf '  Platform:  %s\n' "$platform"
  printf '  Remote:    %s:%s  (%s://%s)\n' "$REMOTE" "$remote_ssh_web_root" "$remote_scheme" "$remote_domain"
  printf '  Local:     %s  (%s://%s)\n' "$local_web_root" "$local_scheme" "$local_domain"
  printf '  Database:  %s@%s:%s/%s  ->  %s@%s:%s/%s  [%s]\n' \
    "$export_db_user" "$export_db_host" "$export_db_port" "$export_db_name" \
    "$import_db_user" "$import_db_host" "$import_db_port" "$import_db_name" "$db_export_method"
  printf '  Files:     sync_mode=%s  rsync_mode=%s\n' "$sync_mode" "$rsync_mode"
  printf '  Mode:      %s\n' "$mode"
  printf '  Env file:  %s\n  Log file:  %s\n' "$ENV_FILE" "$LOG_FILE"
  hr
  printf '  Steps:\n'
  for ((i = 0; i < ${#STEP_IDS[@]}; i++)); do
    reason=$(step_skip_reason "${STEP_IDS[$i]}")
    if [[ -n $reason ]]; then state="${C_GREY}skip${C_RESET}"; else state="${C_GREEN}run ${C_RESET}"; fi
    printf '    [%s] %-16s %s%s\n' "$state" "${STEP_IDS[$i]}" "${STEP_TITLES[$i]}" "${reason:+  (${reason})}"
  done
  hr
  is_dry_run || warn "Steps that run will modify ${local_web_root} and the local database '${import_db_name}'. Back up the local site first if you need it."
}

main() {
  parse_args "$@"
  register_steps
  validate_step_lists
  if [[ $LIST_STEPS == true ]]; then
    ui_init
    list_steps
    exit 0
  fi
  cd "$SCRIPT_DIR" || die "Cannot cd to ${SCRIPT_DIR}"
  load_env_file "$ENV_FILE"
  apply_legacy_aliases
  apply_env_defaults
  normalize_env
  [[ $CLI_PLAIN == true ]] && plain_output=true
  [[ $CLI_AUTO == true ]] && auto_confirm=true
  is_true "$auto_confirm" && AUTO_CONFIRM=true
  ui_init
  if is_true "$skip_migrate_website"; then
    info "skip_migrate_website=true: nothing to do."
    exit 0
  fi
  validate_env || die "Fix the .env problems above and re-run."
  TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/ums.XXXXXX") || die "Cannot create a temp directory"
  chmod 700 "$TMP_DIR"
  trap cleanup EXIT
  trap 'printf "\n"; warn "Interrupted."; exit 130' INT TERM
  ssh_setup
  setup_logging
  detect_platform
  if [[ $CHECK_ONLY == true ]]; then
    preflight_run full
    exit $?
  fi
  print_banner
  confirm "Start the migration?" y y || { info "Aborted."; exit 0; }
  preflight_run || die "Preflight failed. Run ./migrate.sh --check for the full list."
  run_all_steps
  report_finish
}

main "$@"
