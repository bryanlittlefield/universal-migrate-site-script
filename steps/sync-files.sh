#!/usr/bin/env bash
# steps/sync-files.sh — rsync the remote web root down to local_web_root.

step_sync_files() {
  require_vars remote_ssh_host remote_ssh_user remote_ssh_web_root local_web_root || return 1
  run_cmd mkdir -p "$local_web_root" || return 1
  # --omit-dir-times: file mtimes drive rsync's quick check and are kept (-t);
  # directory mtimes don't, and setting them fails (exit 23) when the local
  # account can write to but doesn't own a directory, as on shared hosts.
  local -a opts=(-rlpt --omit-dir-times --human-readable --stats --partial
                 --exclude=/.maintenance --exclude=.git/ --exclude='*.sql' --exclude='*.sql.gz')
  local rsync_log="$log_dir/rsync-${RUN_TAG}.log" rc=0 f

  if [[ $STDOUT_IS_TTY == true ]] && ! is_true "$plain_output" && rsync --info=help >/dev/null 2>&1; then
    opts+=(--info=progress2)
  fi
  case $rsync_mode in
    ignore-existing) opts+=(--ignore-existing) ;;
    mirror) opts+=(--delete) ;;
  esac
  [[ -f $rsync_exclude_file_path ]] && opts+=(--exclude-from="$rsync_exclude_file_path")
  # Excludes come first so they still apply inside an include-only folder.
  case $sync_mode in
    code) opts+=(--exclude="/${uploads_rel_path}/") ;;
    uploads)
      if [[ -n $sync_path && "$uploads_rel_path/" != "$sync_path/"* ]]; then
        warn "sync_mode=uploads copies ${uploads_rel_path}, which is outside sync_path '${sync_path}'"
      fi
      while IFS= read -r f; do opts+=("$f"); done < <(only_path_filters "$uploads_rel_path")
      ;;
  esac
  if [[ -n $sync_path && $sync_mode != uploads ]]; then
    while IFS= read -r f; do opts+=("$f"); done < <(only_path_filters "$sync_path")
  fi
  [[ -n $rsync_bwlimit ]] && opts+=(--bwlimit="$rsync_bwlimit")
  if [[ -n $rsync_extra_opts ]]; then
    local -a extra
    read -r -a extra <<< "$rsync_extra_opts"
    opts+=("${extra[@]}")
  fi
  opts+=(--log-file="$rsync_log")
  is_dry_run && opts+=(--dry-run)
  opts+=(-e "$(rsh_string)")

  [[ -n $sync_path ]] && info "Only syncing the folder '${sync_path}' inside the web root (sync_path)"
  info "Sync mode: ${sync_mode}, rsync mode: ${rsync_mode}, excludes: ${rsync_exclude_file_path}"
  info "rsync ${REMOTE}:${remote_ssh_web_root}/  ->  ${local_web_root}/"
  rsync "${opts[@]}" "${REMOTE}:${remote_ssh_web_root}/" "${local_web_root}/" || rc=$?
  case $rc in
    0) ;;
    23|24)
      warn "rsync finished with warnings (exit ${rc}): some files were skipped or vanished during the transfer. See ${rsync_log}"
      rc=0
      ;;
    *)
      error "rsync failed with exit code ${rc}. See ${rsync_log}"
      return "$rc"
      ;;
  esac
  report_note "rsync log: ${rsync_log}"
  return 0
}
