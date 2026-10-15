#!/usr/bin/env bash
# lib/wp.sh — thin WP-CLI wrappers.

# wpcli ARGS... — a WP-CLI call that changes something (honours --dry-run).
wpcli() {
  local -a extra=()
  [[ -n $wp_cli_extra_opts ]] && read -r -a extra <<< "$wp_cli_extra_opts"
  run_cmd wp --path="$local_web_root" --allow-root ${extra[@]+"${extra[@]}"} "$@"
}

# wpq ARGS... — a read-only WP-CLI call (always runs, output is used).
wpq() {
  local -a extra=()
  [[ -n $wp_cli_extra_opts ]] && read -r -a extra <<< "$wp_cli_extra_opts"
  wp --path="$local_web_root" --allow-root ${extra[@]+"${extra[@]}"} "$@"
}
