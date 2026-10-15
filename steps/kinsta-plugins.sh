#!/usr/bin/env bash
# steps/kinsta-plugins.sh — install Kinsta's must-use plugins (opt-in; only when
# the destination is Kinsta).

step_kinsta_plugins() {
  local mu="$local_web_root/wp-content/mu-plugins" zip="$TMP_DIR/kinsta-mu-plugins.zip"
  if [[ -f $mu/kinsta-mu-plugins.php ]] && ! is_true "$kinsta_force_reinstall"; then
    info "Kinsta MU plugins are already installed (set kinsta_force_reinstall=true to reinstall)."
    return 0
  fi
  info "Downloading ${kinsta_mu_plugins_url}"
  run_cmd curl -fsSL --retry 3 -o "$zip" "$kinsta_mu_plugins_url" || { error "Download failed"; return 1; }
  is_dry_run && return 0
  run_cmd mkdir -p "$mu" || return 1
  unzip -oq "$zip" -d "$mu" || { error "unzip failed"; return 1; }
  [[ -f $mu/kinsta-mu-plugins.php ]] || { error "kinsta-mu-plugins.php not found after unzip"; return 1; }
  ok "Kinsta MU plugins installed into ${mu}"
}
