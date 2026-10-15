#!/usr/bin/env bash
# lib/env.sh — load, alias, default, normalise and validate configuration.
#
# Variable names are deliberately the same as the original migrate-site-script
# so an existing .env keeps working. New options are additive.

load_env_file() {
  local f=$1
  [[ -f $f ]] || die "Env file not found: $f  (copy .env.example to .env and fill it in)"
  set -a
  # shellcheck disable=SC1090
  . "$f"
  set +a
}

# Map variables from the original script onto the new names.
apply_legacy_aliases() {
  if [[ -z ${db_export_method:-} && -n ${db_ssh_tunnels:-} ]]; then
    if is_true "$db_ssh_tunnels"; then db_export_method=tunnel; else db_export_method=remote; fi
  fi
  # The old repo kept list files in its root; fall back to config/ when missing.
  local v val base
  for v in rsync_exclude_file_path db_exclude_tables_file_path wp_search_replace_exclude_file_path; do
    val=${!v:-}
    [[ -n $val && ! -f $val ]] || continue
    base=$(basename "$val")
    [[ -f "config/$base" ]] && printf -v "$v" '%s' "config/$base"
  done
  return 0
}

# Every configuration variable gets a value here so `set -u` is safe and
# the linter can see they are assigned.
apply_env_defaults() {
  # Remote server
  : "${remote_ssh_host:=}" "${remote_ssh_user:=}" "${remote_ssh_port:=22}"
  : "${remote_ssh_key:=}" "${remote_ssh_pass:=}" "${remote_ssh_web_root:=}"
  : "${remote_domain:=}" "${remote_scheme:=https}" "${ssh_strict_host_key:=accept-new}"
  # Remote database
  : "${export_db_name:=}" "${export_db_user:=}" "${export_db_pass:=}"
  : "${export_db_host:=127.0.0.1}" "${export_db_port:=3306}"
  : "${db_export_method:=tunnel}" "${db_ssh_tunnels:=}" "${export_db_filename:=}"
  : "${export_db_ssl_flag:=}" "${db_transfer_compress:=auto}" "${mysqldump_extra_opts:=}"
  # Local server
  : "${local_web_root:=}" "${local_domain:=}" "${local_scheme:=https}"
  : "${import_db_name:=}" "${import_db_user:=}" "${import_db_pass:=}"
  : "${import_db_host:=127.0.0.1}" "${import_db_port:=3306}" "${import_db_ssl_flag:=}"
  : "${create_local_db:=true}" "${local_db_backup:=true}" "${local_db_backup_filename:=}"
  : "${db_fix_collation:=auto}" "${keep_dump:=true}"
  # Platform
  : "${platform:=auto}" "${uploads_rel_path:=}"
  # File sync
  : "${sync_mode:=full}" "${rsync_mode:=sync}" "${rsync_bwlimit:=}" "${rsync_extra_opts:=}"
  : "${rsync_exclude_file_path:=config/rsync-exclude.txt}"
  : "${db_exclude_tables_file_path:=config/db-tables-exclude.txt}"
  : "${wp_search_replace_exclude_file_path:=config/wp-search-replace-exclude.txt}"
  : "${domain_pairs_file_path:=config/domain-pairs.txt}"
  : "${host_mu_plugins_file_path:=config/host-mu-plugins.txt}"
  : "${host_plugins_deactivate_file_path:=config/host-plugins-deactivate.txt}"
  : "${wpe_config_patterns_file_path:=config/wpe-config-patterns.txt}"
  : "${replace_www_variant:=true}" "${wp_cli_extra_opts:=}"
  # WordPress local settings
  : "${wp_environment_type:=local}" "${wp_debug:=true}" "${wp_discourage_search_engines:=true}"
  : "${wp_remove_dropins:=true}" "${wp_local_admin_user:=}" "${wp_local_admin_pass:=}" "${wp_local_admin_email:=}"
  # Laravel local settings
  : "${laravel_app_env:=local}" "${laravel_app_debug:=true}"
  # Kinsta
  : "${kinsta_mu_plugins_url:=https://kinsta.com/kinsta-tools/kinsta-mu-plugins.zip}" "${kinsta_force_reinstall:=false}"
  # Behaviour
  : "${auto_confirm:=false}" "${continue_on_error:=false}" "${plain_output:=false}"
  : "${log_dir:=logs}" "${dump_dir:=dumps}" "${preflight_disk_check:=false}"
  : "${verify_http:=true}" "${verify_db_check:=false}"
  # Step toggles
  : "${skip_migrate_website:=false}" "${skip_clear_web_root:=false}" "${skip_maintenance:=false}"
  : "${skip_file_sync:=false}" "${skip_db_import:=false}" "${skip_app_config:=false}"
  : "${skip_host_cleanup:=false}" "${skip_kinsta_plugins:=false}" "${skip_local_hardening:=false}"
  : "${skip_cache_refresh:=false}" "${skip_verify:=false}"
  : "${run_clear_web_root:=false}" "${run_kinsta_plugins:=false}"
}

normalize_env() {
  local_web_root=$(normalize_dir "$local_web_root")
  remote_ssh_web_root=$(normalize_dir "$remote_ssh_web_root")
  remote_domain=$(normalize_domain "$remote_domain")
  local_domain=$(normalize_domain "$local_domain")
  platform=$(to_lower "$platform"); [[ -z $platform ]] && platform=auto
  db_export_method=$(to_lower "$db_export_method")
  sync_mode=$(to_lower "$sync_mode")
  rsync_mode=$(to_lower "$rsync_mode")
  remote_scheme=$(to_lower "$remote_scheme")
  local_scheme=$(to_lower "$local_scheme")
  db_fix_collation=$(to_lower "$db_fix_collation")
  return 0
}

validate_env() {
  local bad=0
  if [[ -z $local_web_root ]]; then error "local_web_root is required"; bad=1; fi
  case $platform in wordpress|laravel|auto) ;; *) error "platform must be wordpress, laravel or auto (got '$platform')"; bad=1 ;; esac
  case $db_export_method in tunnel|remote) ;; *) error "db_export_method must be tunnel or remote (got '$db_export_method')"; bad=1 ;; esac
  case $sync_mode in full|code|uploads) ;; *) error "sync_mode must be full, code or uploads (got '$sync_mode')"; bad=1 ;; esac
  case $rsync_mode in sync|ignore-existing|mirror) ;; *) error "rsync_mode must be sync, ignore-existing or mirror (got '$rsync_mode')"; bad=1 ;; esac
  case $local_scheme in http|https) ;; *) error "local_scheme must be http or https"; bad=1 ;; esac
  case $remote_scheme in http|https) ;; *) error "remote_scheme must be http or https"; bad=1 ;; esac
  case $ssh_strict_host_key in yes|no|accept-new) ;; *) error "ssh_strict_host_key must be yes, no or accept-new"; bad=1 ;; esac
  case $db_fix_collation in auto|true|false) ;; *) error "db_fix_collation must be auto, true or false"; bad=1 ;; esac
  return $bad
}

# require_vars NAME... — error listing any that are empty.
require_vars() {
  local -a missing=()
  local v
  for v in "$@"; do
    [[ -n ${!v:-} ]] || missing+=("$v")
  done
  if ((${#missing[@]})); then
    error "Missing required .env values: ${missing[*]}"
    return 1
  fi
  return 0
}

detect_platform() {
  if [[ $platform == auto ]]; then
    if [[ -f $local_web_root/wp-config.php || -d $local_web_root/wp-includes ]]; then
      platform=wordpress
    elif [[ -f $local_web_root/artisan ]]; then
      platform=laravel
    elif [[ -n $remote_ssh_host ]] && ssh_run "test -f $(shell_quote "$remote_ssh_web_root/wp-config.php") || test -d $(shell_quote "$remote_ssh_web_root/wp-includes")" >/dev/null 2>&1; then
      platform=wordpress
    elif [[ -n $remote_ssh_host ]] && ssh_run "test -f $(shell_quote "$remote_ssh_web_root/artisan")" >/dev/null 2>&1; then
      platform=laravel
    else
      platform=unknown
      warn "Could not detect the platform locally or remotely; platform-specific steps will be skipped. Set platform= in .env."
    fi
    info "Detected platform: $platform"
  fi
  if [[ -z $uploads_rel_path ]]; then
    case $platform in
      laravel) uploads_rel_path="storage/app/public" ;;
      *) uploads_rel_path="wp-content/uploads" ;;
    esac
  fi
  uploads_rel_path=${uploads_rel_path#/}
  uploads_rel_path=${uploads_rel_path%/}
}
