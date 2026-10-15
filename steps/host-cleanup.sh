#!/usr/bin/env bash
# steps/host-cleanup.sh — remove WP Engine settings, host mu-plugins and cache drop-ins.

step_host_cleanup() {
  local cfg="$local_web_root/wp-config.php" pat removed=0 n entry path
  if [[ ! -f $cfg ]]; then
    warn "No wp-config.php in ${local_web_root}; skipping config cleanup."
  elif grep -qE 'WPE_|PWP_|wpengine|is_wpe' "$cfg"; then
    info "WP Engine settings detected in wp-config.php"
    if is_dry_run; then
      info "[dry-run] would strip WP Engine lines from wp-config.php"
    else
      cp "$cfg" "${cfg}.bak-${RUN_TAG}" || return 1
      report_note "wp-config.php backup: ${cfg}.bak-${RUN_TAG}"
      while IFS= read -r pat; do
        [[ -n $pat ]] || continue
        n=$(grep -cE -- "$pat" "$cfg" || true)
        ((n > 0)) || continue
        sed_inplace -E "\|${pat}|d" "$cfg" || return 1
        removed=$((removed + n))
      done <<< "$(read_list_file "$wpe_config_patterns_file_path")"
      sed_inplace '/^$/N;/^\n$/D' "$cfg"
      info "Removed ${removed} WP Engine line(s) from wp-config.php"
    fi
  else
    info "No WP Engine markers in wp-config.php; leaving it untouched."
  fi

  while IFS= read -r entry; do
    [[ -n $entry ]] || continue
    path="$local_web_root/wp-content/mu-plugins/${entry#/}"
    if [[ -e $path ]]; then
      info "Removing mu-plugin: ${entry}"
      run_cmd rm -rf -- "$path" || return 1
    fi
  done <<< "$(read_list_file "$host_mu_plugins_file_path")"

  if is_true "$wp_remove_dropins"; then
    for entry in object-cache.php advanced-cache.php; do
      path="$local_web_root/wp-content/${entry}"
      if [[ -f $path ]]; then
        info "Removing drop-in: wp-content/${entry}"
        run_cmd rm -f -- "$path" || return 1
      fi
    done
  fi
  return 0
}
