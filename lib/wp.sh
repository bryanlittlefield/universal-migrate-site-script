#!/usr/bin/env bash
# lib/wp.sh — thin WP-CLI wrappers.
#
# WP_PATH is the WordPress core folder (wp_cli_path, default local_web_root)
# and WP_CONFIG_FILE the config file (wp_config_path, default
# local_web_root/wp-config.php). A custom config path is exported as WP_CONFIG_PATH
# (see normalize_env) and also passed to `wp config …` as --config-file.

# wp_args ARGS... — fills WP_ARGS with the full argument list for wp.
# Global flags (--quiet) are moved in front of the command: hosts that set
# WP_CLI_STRICT_ARGS_MODE treat anything after the command as a command
# argument and fail with "unknown --quiet parameter".
wp_args() {
  local -a extra=() global=() rest=()
  local a
  [[ -n $wp_cli_extra_opts ]] && read -r -a extra <<< "$wp_cli_extra_opts"
  for a in "$@"; do
    if [[ $a == --quiet ]]; then global+=("$a"); else rest+=("$a"); fi
  done
  WP_ARGS=(--path="${WP_PATH:-$local_web_root}" --allow-root ${extra[@]+"${extra[@]}"}
           ${global[@]+"${global[@]}"} ${rest[@]+"${rest[@]}"})
  if [[ -n ${wp_config_path:-} && ${1-} == config ]]; then WP_ARGS+=(--config-file="$wp_config_path"); fi
}

# wpcli ARGS... — a WP-CLI call that changes something (honours --dry-run).
wpcli() {
  wp_args "$@"
  run_cmd wp "${WP_ARGS[@]}"
}

# wpq ARGS... — a read-only WP-CLI call (always runs, output is used).
wpq() {
  wp_args "$@"
  wp "${WP_ARGS[@]}"
}
