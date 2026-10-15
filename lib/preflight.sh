#!/usr/bin/env bash
# lib/preflight.sh — fail early, before anything destructive happens.

PF_FAIL=0
PF_WARN=0

pf_ok() { printf '  %s%s%s %s\n' "${C_GREEN}" "${I_OK}" "${C_RESET}" "$*"; }
pf_fail() { printf '  %s%s%s %s\n' "${C_RED}" "${I_FAIL}" "${C_RESET}" "$*"; PF_FAIL=$((PF_FAIL + 1)); }
pf_warn() { printf '  %s%s%s %s\n' "${C_YELLOW}" "${I_WARN}" "${C_RESET}" "$*"; PF_WARN=$((PF_WARN + 1)); }

# preflight_run [full] — "full" adds the (slow) disk-space comparison.
preflight_run() {
  local mode=${1:-quick}
  PF_FAIL=0; PF_WARN=0
  section "Preflight checks"
  pf_check_binaries
  pf_check_local_root
  pf_check_ssh
  pf_check_remote_db
  pf_check_local_db
  if [[ $mode == full ]] || is_true "$preflight_disk_check"; then pf_check_disk; fi
  hr
  if ((PF_FAIL)); then
    error "${PF_FAIL} preflight check(s) failed."
    return 1
  fi
  ok "Preflight passed (${PF_WARN} warning(s))."
}

pf_check_binaries() {
  local need="" optional="pv gzip" b
  pf_need() { in_csv "$1" "${need//,/,}" || need="${need:+$need,}$1"; }
  if step_enabled sync-files || step_enabled migrate-db; then pf_need ssh; fi
  step_enabled sync-files && pf_need rsync
  if step_enabled migrate-db; then
    pf_need mysql
    [[ $db_export_method == tunnel ]] && pf_need mysqldump
    is_true "$local_db_backup" && pf_need mysqldump
  fi
  [[ -z $remote_ssh_key && -n $remote_ssh_pass ]] && pf_need sshpass
  if [[ $platform == wordpress ]]; then
    if step_enabled app-config || step_enabled local-hardening || step_enabled cache-refresh || step_enabled verify; then pf_need wp; fi
  fi
  [[ $platform == laravel ]] && pf_need php
  if step_enabled kinsta-plugins; then pf_need curl; pf_need unzip; fi
  step_enabled verify && is_true "$verify_http" && optional="$optional curl"
  local IFS=,
  for b in $need; do
    if have_cmd "$b"; then pf_ok "found $b"; else pf_fail "missing: $b  (Debian/Ubuntu: apt-get install -y $b)"; fi
  done
  IFS=' '
  for b in $optional; do
    have_cmd "$b" || in_csv "$b" "$need" || pf_warn "optional tool not found: $b"
  done
  return 0
}

pf_check_local_root() {
  if [[ -d $local_web_root ]]; then
    if [[ -w $local_web_root ]]; then pf_ok "Local web root is writable: $local_web_root"; else pf_fail "Local web root is not writable: $local_web_root"; fi
  elif step_enabled sync-files; then
    pf_warn "Local web root does not exist yet and will be created: $local_web_root"
  else
    pf_fail "Local web root does not exist: $local_web_root"
  fi
  if [[ $platform == wordpress && -d $local_web_root && ! -f $local_web_root/wp-config.php ]] && ! step_enabled sync-files; then
    pf_warn "No wp-config.php in $local_web_root and file sync is disabled; WordPress steps will fail"
  fi
  return 0
}

pf_check_ssh() {
  step_enabled sync-files || step_enabled migrate-db || return 0
  if ! require_vars remote_ssh_host remote_ssh_user remote_ssh_web_root >/dev/null 2>&1; then
    pf_fail "remote_ssh_host, remote_ssh_user and remote_ssh_web_root are required"
    return 0
  fi
  if [[ -n $remote_ssh_key && ! -f $remote_ssh_key ]]; then
    pf_fail "remote_ssh_key not found: $remote_ssh_key"
    return 0
  fi
  [[ -z $remote_ssh_key && -z $remote_ssh_pass ]] && pf_warn "No remote_ssh_key or remote_ssh_pass set; relying on ssh-agent or interactive password prompts"
  if ssh_run 'echo ok' >/dev/null 2>"$TMP_DIR/ssh.err"; then
    pf_ok "SSH to ${REMOTE} (port ${remote_ssh_port})"
  else
    pf_fail "SSH to ${REMOTE} failed: $(tail -n 1 "$TMP_DIR/ssh.err" 2>/dev/null)"
    return 0
  fi
  if ssh_run "test -d $(shell_quote "$remote_ssh_web_root")" >/dev/null 2>&1; then
    pf_ok "Remote web root exists: $remote_ssh_web_root"
  else
    pf_fail "Remote web root not found: $remote_ssh_web_root"
  fi
  return 0
}

pf_check_remote_db() {
  step_enabled migrate-db || return 0
  if ! require_vars export_db_name export_db_user >/dev/null 2>&1; then
    pf_fail "export_db_name and export_db_user are required"
    return 0
  fi
  if db_init_remote 2>"$TMP_DIR/rdb.err" && remote_query 'SELECT 1' >/dev/null 2>>"$TMP_DIR/rdb.err"; then
    pf_ok "Remote database '${export_db_name}' reachable (${db_export_method} method)"
  else
    pf_fail "Remote database check failed: $(tail -n 1 "$TMP_DIR/rdb.err" 2>/dev/null)"
  fi
  db_teardown_remote
  return 0
}

pf_check_local_db() {
  step_enabled migrate-db || return 0
  if ! require_vars import_db_name import_db_user >/dev/null 2>&1; then
    pf_fail "import_db_name and import_db_user are required"
    return 0
  fi
  db_init_local || { pf_fail "Could not prepare local DB client configuration"; return 0; }
  if mysql_local -e 'SELECT 1' >/dev/null 2>"$TMP_DIR/ldb.err"; then
    pf_ok "Local DB server ${import_db_host}:${import_db_port} reachable as ${import_db_user}"
  else
    pf_fail "Local DB connection failed: $(tail -n 1 "$TMP_DIR/ldb.err" 2>/dev/null)"
    return 0
  fi
  if local_db_exists; then
    pf_ok "Local database '${import_db_name}' exists"
  elif is_true "$create_local_db"; then
    pf_warn "Local database '${import_db_name}' is missing and will be created"
  else
    pf_fail "Local database '${import_db_name}' is missing (set create_local_db=true to create it)"
  fi
  return 0
}

pf_check_disk() {
  step_enabled sync-files || return 0
  local remote_kb local_kb target
  remote_kb=$(ssh_run "du -sk $(shell_quote "$remote_ssh_web_root") 2>/dev/null | cut -f1" 2>/dev/null | tr -d '[:space:]')
  target=$local_web_root
  [[ -d $target ]] || target=$(dirname "$target")
  local_kb=$(df -Pk "$target" 2>/dev/null | awk 'NR==2 {print $4}')
  if [[ -z $remote_kb || -z $local_kb ]]; then
    pf_warn "Could not compare disk space (remote=${remote_kb:-?}KB free-local=${local_kb:-?}KB)"
    return 0
  fi
  if ((local_kb < remote_kb * 11 / 10)); then
    pf_fail "Not enough free space: remote site is $((remote_kb / 1024))MB, local free space is $((local_kb / 1024))MB"
  else
    pf_ok "Disk space: remote site $((remote_kb / 1024))MB, local free $((local_kb / 1024))MB"
  fi
  return 0
}
