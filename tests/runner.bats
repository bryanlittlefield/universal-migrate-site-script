#!/usr/bin/env bats
load test_helper

step_a() { echo A-ran; }
step_b() { echo B-ran; }
step_c() { echo C-ran; return 3; }

setup() {
  load_libs
  T=$(new_tmp)
  register_step a "Step A" step_a all y "A"
  register_step b "Step B" step_b wordpress n "B"
  register_step c "Step C" step_c all y "C"
  platform=wordpress AUTO_CONFIRM=true ONLY_STEPS="" SKIP_STEPS="" WITH_STEPS="" continue_on_error=false
  RUN_START=0 LOG_FILE=/dev/null REPORT_FILE="$T/report.txt" VERSION=test REMOTE=u@h
  remote_ssh_web_root=/r remote_domain=o local_web_root=/l local_domain=n export_db_name=e import_db_name=i db_export_method=tunnel
}
teardown() { rm -rf "$T"; }

@test "opt-in steps are skipped under --yes unless enabled" {
  [ "$(step_skip_reason b)" = "opt-in step; enable with --with b" ]
  WITH_STEPS=b; [ -z "$(step_skip_reason b)" ]
  WITH_STEPS=""; ONLY_STEPS=b; [ -z "$(step_skip_reason b)" ]
  ONLY_STEPS=""; run_b=true; [ -z "$(step_skip_reason b)" ]
}

@test "opt-in steps prompt normally in interactive mode" {
  AUTO_CONFIRM=false
  [ -z "$(step_skip_reason b)" ]
}

@test "platform mismatch skips the step" {
  platform=laravel
  [ "$(step_skip_reason b)" = "platform is laravel" ]
  [ -z "$(step_skip_reason a)" ]
}

@test "--skip, skip_<id> and --only" {
  SKIP_STEPS=a; [ "$(step_skip_reason a)" = "--skip" ]
  SKIP_STEPS=""; skip_a=true; [ "$(step_skip_reason a)" = "skip_a=true" ]
  skip_a=false; ONLY_STEPS=c; [ "$(step_skip_reason a)" = "not in --only" ]; [ -z "$(step_skip_reason c)" ]
}

@test "skip_var_for keeps the original script's variable names" {
  [ "$(skip_var_for sync-files)" = skip_file_sync ]
  [ "$(skip_var_for migrate-db)" = skip_db_import ]
  [ "$(skip_var_for maintenance-off)" = skip_maintenance ]
  [ "$(skip_var_for cache-refresh)" = skip_cache_refresh ]
  [ "$(skip_var_for something-new)" = skip_something_new ]
}

@test "a failed step is recorded, stops the run and fails the report" {
  run_all_steps >/dev/null 2>&1 || true
  [ "${#FAILED_STEPS[@]}" -eq 1 ]
  [ "${FAILED_STEPS[0]}" = c ]
  [[ ${REPORT_LINES[0]} == *"Step A"* ]]
  [[ ${REPORT_LINES[1]} == *"Step B"*skipped* ]]
  [[ ${REPORT_LINES[2]} == *"Step C"*FAILED* ]]
  run report_finish
  [ "$status" -eq 1 ]
  [ -f "$T/report.txt" ]
  grep -q "Step C" "$T/report.txt"
}

@test "continue_on_error keeps going after a failure" {
  continue_on_error=true
  register_step d "Step D" step_a all y "D"
  run_all_steps >/dev/null 2>&1 || true
  [[ ${REPORT_LINES[3]} == *"Step D"* ]]
  [[ ${REPORT_LINES[3]} != *FAILED* ]]
}
