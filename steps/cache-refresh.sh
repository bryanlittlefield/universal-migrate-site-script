#!/usr/bin/env bash
# steps/cache-refresh.sh — flush caches and rewrite rules.

step_cache_refresh() {
  case $platform in
    wordpress)
      wpcli rewrite flush --quiet || return 1
      wpcli cache flush --quiet || return 1
      wpcli transient delete --all --quiet || warn "Could not delete transients"
      if wpq cli has-command 'kinsta cache purge' >/dev/null 2>&1; then
        wpcli kinsta cache purge || warn "Kinsta cache purge failed"
      fi
      ;;
    laravel)
      run_cmd php "$local_web_root/artisan" optimize:clear || return 1
      ;;
    *)
      info "No cache handling for platform '${platform}'."
      ;;
  esac
  return 0
}
