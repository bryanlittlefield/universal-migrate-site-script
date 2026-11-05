#!/usr/bin/env bash
# steps/hooks.sh — user commands that run before the first step and after the last.
#
# before_run_hook / after_run_hook hold either a path to a script (absolute, or
# relative to the script directory; run with bash) or a shell command line.
# The hook runs in local_web_root when it exists, otherwise in the script
# directory, with stdin closed and the main settings exported as UMS_* variables.
# A non-zero exit fails the step like any other.

run_hook() {
  local var=$1 hook=${!1} dir=$SCRIPT_DIR
  local -a cmd
  [[ -d $local_web_root ]] && dir=$local_web_root
  if [[ $hook == /* && -f $hook ]]; then
    cmd=(bash "$hook")
  elif [[ -f $SCRIPT_DIR/$hook ]]; then
    cmd=(bash "$SCRIPT_DIR/$hook")
  else
    cmd=(bash -c "$hook")
  fi
  info "Running ${var} in ${dir}"
  (
    cd "$dir" || exit 1
    export UMS_HOOK=${var%_hook} UMS_ENV_FILE=$ENV_FILE UMS_PLATFORM=$platform \
      UMS_LOCAL_WEB_ROOT=$local_web_root UMS_LOCAL_URL="${local_scheme}://${local_domain}" \
      UMS_REMOTE_URL="${remote_scheme}://${remote_domain}" UMS_IMPORT_DB_NAME=$import_db_name \
      UMS_LOG_FILE=$LOG_FILE UMS_RUN_TAG=$RUN_TAG UMS_DRY_RUN=$DRY_RUN \
      UMS_FAILED_STEPS="${FAILED_STEPS[*]+${FAILED_STEPS[*]}}"
    run_cmd "${cmd[@]}" < /dev/null
  )
}

step_before_run() { run_hook before_run_hook; }
step_after_run() { run_hook after_run_hook; }
