#!/usr/bin/env bash
# steps/maintenance.sh — put the LOCAL site into / out of maintenance mode.
# WordPress: a .maintenance file that does not expire (core's own expires after
# 10 minutes, which is shorter than most syncs). Laravel: artisan down / up.

step_maintenance_on() {
  case $platform in
    wordpress)
      # WordPress looks for .maintenance in ABSPATH, i.e. the core folder.
      if [[ ! -d $WP_PATH ]]; then
        info "WordPress folder does not exist yet; nothing to put into maintenance mode."
        return 0
      fi
      if [[ ! -w $WP_PATH ]]; then
        warn "Cannot write to ${WP_PATH} (host-managed WordPress core?); skipping maintenance mode."
        return 0
      fi
      if is_dry_run; then
        info "[dry-run] would write ${WP_PATH}/.maintenance"
        return 0
      fi
      printf '<?php $upgrading = time(); ?>\n' > "$WP_PATH/.maintenance" || return 1
      MAINT_ACTIVE=true
      info "Maintenance mode enabled (${WP_PATH}/.maintenance)"
      ;;
    laravel)
      [[ -f $local_web_root/artisan ]] || { info "No artisan file yet; skipping."; return 0; }
      run_cmd php "$local_web_root/artisan" down --retry=60 || return 1
      MAINT_ACTIVE=true
      ;;
    *)
      info "Platform '${platform}' has no maintenance mode handling."
      ;;
  esac
  return 0
}

step_maintenance_off() {
  case $platform in
    wordpress)
      if [[ -f $WP_PATH/.maintenance ]]; then
        run_cmd rm -f -- "$WP_PATH/.maintenance" || return 1
        info "Maintenance mode disabled"
      else
        info "No .maintenance file present."
      fi
      MAINT_ACTIVE=false
      ;;
    laravel)
      [[ -f $local_web_root/artisan ]] || return 0
      run_cmd php "$local_web_root/artisan" up || return 1
      MAINT_ACTIVE=false
      ;;
  esac
  return 0
}
