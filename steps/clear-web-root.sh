#!/usr/bin/env bash
# steps/clear-web-root.sh — delete everything inside local_web_root (opt-in).

step_clear_web_root() {
  local root=$local_web_root depth typed name
  if [[ -z $root || $root == / || $root == . || $root == "$HOME" || $root == "$SCRIPT_DIR" || $SCRIPT_DIR == "$root"/* ]]; then
    error "Refusing to clear suspicious web root: '${root}'"
    return 1
  fi
  if [[ $root != /* ]]; then
    error "local_web_root must be an absolute path to clear it (got '${root}')"
    return 1
  fi
  depth=$(printf '%s' "$root" | tr -cd '/' | wc -c | tr -d ' ')
  if ((depth < 2)); then
    error "Refusing to clear a top-level directory: ${root}"
    return 1
  fi
  if [[ ! -d $root ]]; then
    info "Web root does not exist yet; nothing to clear."
    return 0
  fi
  warn "This deletes EVERYTHING inside ${root}, including dotfiles."
  if ! is_true "$AUTO_CONFIRM"; then
    name=$(basename "$root")
    printf 'Type the directory name "%s" to confirm: ' "$name"
    read -r typed || typed=""
    if [[ $typed != "$name" ]]; then
      warn "Confirmation did not match; web root NOT cleared."
      return 1
    fi
  fi
  if is_dry_run; then
    info "[dry-run] would delete the contents of ${root}"
    WEB_ROOT_CLEARED=true
    return 0
  fi
  find "$root" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} + || { error "Failed to clear ${root}"; return 1; }
  WEB_ROOT_CLEARED=true
  ok "Cleared ${root}"
}
