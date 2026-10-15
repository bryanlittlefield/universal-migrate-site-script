#!/usr/bin/env bash
# lib/runner.sh — step registry, skip logic, timing and the final report.
#
# A step is a bash function that returns 0 on success. The runner handles the
# prompt, skip flags, timing, exit-code capture and the report line, so steps
# only contain the actual work.

STEP_IDS=()
STEP_TITLES=()
STEP_FUNCS=()
STEP_PLATFORMS=()
STEP_DEFAULTS=()
STEP_DESCS=()
REPORT_LINES=()
FAILED_STEPS=()
STOP_REQUESTED=false

# register_step ID TITLE FUNCTION PLATFORMS DEFAULT(y|n) DESCRIPTION
#   PLATFORMS: "all" or a comma list (wordpress,laravel)
#   DEFAULT n = opt-in step: prompts with [y/N]; with --yes it only runs when
#               enabled via --with ID, --only ID or run_<id>=true
register_step() {
  STEP_IDS+=("$1"); STEP_TITLES+=("$2"); STEP_FUNCS+=("$3")
  STEP_PLATFORMS+=("$4"); STEP_DEFAULTS+=("$5"); STEP_DESCS+=("$6")
}

step_index() {
  local i
  for ((i = 0; i < ${#STEP_IDS[@]}; i++)); do
    [[ ${STEP_IDS[$i]} == "$1" ]] && { printf '%s' "$i"; return 0; }
  done
  return 1
}

# The .env variable that skips a step (names kept from the original script).
skip_var_for() {
  case $1 in
    clear-web-root) printf 'skip_clear_web_root' ;;
    maintenance-on|maintenance-off) printf 'skip_maintenance' ;;
    sync-files) printf 'skip_file_sync' ;;
    migrate-db) printf 'skip_db_import' ;;
    app-config) printf 'skip_app_config' ;;
    host-cleanup) printf 'skip_host_cleanup' ;;
    kinsta-plugins) printf 'skip_kinsta_plugins' ;;
    local-hardening) printf 'skip_local_hardening' ;;
    cache-refresh) printf 'skip_cache_refresh' ;;
    verify) printf 'skip_verify' ;;
    *) printf 'skip_%s' "${1//-/_}" ;;
  esac
}

# step_skip_reason ID — prints why the step will not run, or nothing.
step_skip_reason() {
  local id=$1 i platforms default var runvar
  i=$(step_index "$id") || { printf 'unknown step'; return 0; }
  platforms=${STEP_PLATFORMS[$i]}
  default=${STEP_DEFAULTS[$i]}
  if [[ -n ${ONLY_STEPS:-} ]] && ! in_csv "$id" "$ONLY_STEPS"; then printf 'not in --only'; return 0; fi
  if in_csv "$id" "${SKIP_STEPS:-}"; then printf -- '--skip'; return 0; fi
  var=$(skip_var_for "$id")
  if is_true "${!var:-false}"; then printf '%s=true' "$var"; return 0; fi
  if [[ $platforms != all ]] && ! in_csv "${platform:-unknown}" "$platforms"; then printf 'platform is %s' "${platform:-unknown}"; return 0; fi
  if [[ $id == maintenance-on && ${WEB_ROOT_CLEARED:-false} == true ]]; then printf 'web root was cleared'; return 0; fi
  if [[ $default == n ]] && is_true "${AUTO_CONFIRM:-false}"; then
    runvar="run_${id//-/_}"
    if ! in_csv "$id" "${WITH_STEPS:-}" && ! in_csv "$id" "${ONLY_STEPS:-}" && ! is_true "${!runvar:-false}"; then
      printf 'opt-in step; enable with --with %s' "$id"
      return 0
    fi
  fi
  printf ''
}

step_enabled() { [[ -z $(step_skip_reason "$1") ]]; }

report_add() { REPORT_LINES+=("$1 $2"); }
report_note() { REPORT_LINES+=("      $*"); }

run_step() {
  local i=$1 id title fn default reason rc start elapsed runvar
  id=${STEP_IDS[$i]}; title=${STEP_TITLES[$i]}; fn=${STEP_FUNCS[$i]}; default=${STEP_DEFAULTS[$i]}
  reason=$(step_skip_reason "$id")
  if [[ -n $reason ]]; then
    report_add "${I_SKIP}" "${title} — skipped (${reason})"
    return 0
  fi
  runvar="run_${id//-/_}"
  is_true "${!runvar:-false}" && default=y
  printf '\n'
  if ! confirm "Run step '${title}'?" "$default" y; then
    report_add "${I_SKIP}" "${title} — skipped by user"
    return 0
  fi
  section "$title"
  start=$SECONDS
  CURRENT_STEP=$id
  if "$fn"; then rc=0; else rc=$?; fi
  elapsed=$((SECONDS - start))
  if ((rc == 0)); then
    ok "${title} finished in $(fmt_duration "$elapsed")"
    report_add "${I_OK}" "${title} ($(fmt_duration "$elapsed"))"
  else
    error "${title} FAILED (exit ${rc}) after $(fmt_duration "$elapsed")"
    report_add "${I_FAIL}" "${title} — FAILED, exit ${rc} ($(fmt_duration "$elapsed"))"
    FAILED_STEPS+=("$id")
    local auto_answer=n
    is_true "$continue_on_error" && auto_answer=y
    if ! confirm "Continue with the remaining steps?" n "$auto_answer"; then
      warn "Stopping after failed step '${id}'."
      STOP_REQUESTED=true
      return 1
    fi
  fi
  return 0
}

run_all_steps() {
  local i
  for ((i = 0; i < ${#STEP_IDS[@]}; i++)); do
    run_step "$i" || break
  done
}

list_steps() {
  local i mode
  printf '%-16s %-7s %-18s %s\n' "ID" "MODE" "PLATFORMS" "DESCRIPTION"
  for ((i = 0; i < ${#STEP_IDS[@]}; i++)); do
    mode=run; [[ ${STEP_DEFAULTS[$i]} == n ]] && mode=opt-in
    printf '%-16s %-7s %-18s %s\n' "${STEP_IDS[$i]}" "$mode" "${STEP_PLATFORMS[$i]}" "${STEP_DESCS[$i]}"
  done
}

report_finish() {
  local total=$((SECONDS - RUN_START)) line
  printf '\n'
  hr
  printf '%s%s Migration report — %s%s\n' "${C_BOLD}" "${I_INFO}" "$(ts)" "${C_RESET}"
  hr
  for line in ${REPORT_LINES[@]+"${REPORT_LINES[@]}"}; do printf '  %s\n' "$line"; done
  hr
  printf '  Total time: %s\n  Log file:   %s\n  Report:     %s\n' "$(fmt_duration "$total")" "$LOG_FILE" "$REPORT_FILE"
  hr
  {
    printf 'universal-migrate-site-script %s — %s\n' "$VERSION" "$(ts)"
    printf 'Platform: %s\nRemote:   %s:%s (%s)\nLocal:    %s (%s)\nDatabase: %s -> %s (%s)\n\n' \
      "$platform" "$REMOTE" "$remote_ssh_web_root" "$remote_domain" "$local_web_root" "$local_domain" \
      "$export_db_name" "$import_db_name" "$db_export_method"
    for line in ${REPORT_LINES[@]+"${REPORT_LINES[@]}"}; do printf '%s\n' "$line"; done
    printf '\nTotal time: %s\nLog file: %s\n' "$(fmt_duration "$total")" "$LOG_FILE"
  } > "$REPORT_FILE"
  if ((${#FAILED_STEPS[@]})); then
    error "Finished with ${#FAILED_STEPS[@]} failed step(s): ${FAILED_STEPS[*]}"
    return 1
  fi
  ok "Migration finished."
}
