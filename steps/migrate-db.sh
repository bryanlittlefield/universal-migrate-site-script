#!/usr/bin/env bash
# steps/migrate-db.sh — export the remote database, back up and replace the local one.

step_migrate_db() {
  require_vars export_db_name export_db_user import_db_name import_db_user || return 1
  db_init_local || return 1
  run_cmd mkdir -p "$dump_dir" || return 1
  local dump_file=$export_db_filename lver count
  [[ -n $dump_file ]] || dump_file="$dump_dir/${export_db_name}-${RUN_TAG}.sql"

  lver=$(local_server_version 2>"$TMP_DIR/ldb.err") || {
    error "Cannot connect to the local DB server: $(tail -n 1 "$TMP_DIR/ldb.err" 2>/dev/null)"
    return 1
  }
  info "Local DB server: ${lver}"
  FIX_COLLATION=false
  case $db_fix_collation in
    true) FIX_COLLATION=true ;;
    auto) should_fix_collation "$lver" && FIX_COLLATION=true ;;
  esac
  [[ $FIX_COLLATION == true ]] && info "MySQL 8 collations (utf8mb4_0900_*) will be mapped to ones this server supports"

  if ! local_db_exists; then
    if is_true "$create_local_db"; then
      info "Creating local database '${import_db_name}'"
      run_cmd mysql_local -e "CREATE DATABASE \`${import_db_name}\` CHARACTER SET utf8mb4" || return 1
    else
      error "Local database '${import_db_name}' does not exist (set create_local_db=true to create it)"
      return 1
    fi
  fi

  db_export_to "$dump_file" || { db_teardown_remote; return 1; }
  db_teardown_remote
  is_dry_run && return 0

  count=$(local_table_count 2>/dev/null || printf 0)
  if ((count > 0)) && is_true "$local_db_backup"; then
    backup_local_db || return 1
    report_note "Local DB backup: ${LOCAL_DB_BACKUP_FILE}"
  fi
  info "Dropping ${count} existing table(s)/view(s) in '${import_db_name}'"
  drop_all_local_tables || { error "Could not drop the existing tables"; return 1; }
  info "Importing ${dump_file} ($(($(file_size "$dump_file") / 1024 / 1024))MB)"
  import_dump_file "$dump_file" || { error "Import failed"; return 1; }
  LOCAL_TABLE_COUNT=$(local_table_count 2>/dev/null || printf '?')
  DB_MIGRATED=true
  ok "Imported ${LOCAL_TABLE_COUNT} table(s) (remote had ${REMOTE_TABLE_COUNT:-?})"
  report_note "Tables: remote ${REMOTE_TABLE_COUNT:-?}, local ${LOCAL_TABLE_COUNT}"
  if is_true "$keep_dump"; then report_note "Dump kept: ${dump_file}"; else rm -f -- "$dump_file"; fi
  return 0
}

# db_export_to FILE — export the remote database, honouring the table exclude list.
db_export_to() {
  local out=$1 tables patterns excluded t
  local -a ignore_opts=() base
  db_init_remote || return 1
  info "Listing remote tables"
  tables=$(remote_query 'SHOW TABLES' 2>"$TMP_DIR/rdb.err") || {
    error "Could not list remote tables: $(tail -n 1 "$TMP_DIR/rdb.err" 2>/dev/null)"
    return 1
  }
  REMOTE_TABLE_COUNT=$(printf '%s\n' "$tables" | grep -c . || true)
  info "Remote database '${export_db_name}' has ${REMOTE_TABLE_COUNT} table(s)"

  patterns=$(read_list_file "$db_exclude_tables_file_path")
  if [[ -n $patterns ]]; then
    excluded=$(resolve_table_patterns "$tables" "$patterns")
    while IFS= read -r t; do
      [[ -n $t ]] || continue
      ignore_opts+=("--ignore-table=${export_db_name}.${t}")
      info "Data excluded (structure only): ${t}"
    done <<< "$excluded"
    while IFS= read -r t; do
      [[ -n $t && $t != *[\*\?]* ]] || continue
      printf '%s\n' "$tables" | grep -qx -- "$t" || warn "Exclude list names '${t}' but the remote database has no such table"
    done <<< "$patterns"
  fi

  base=(--quick --single-transaction --no-tablespaces --default-character-set=utf8mb4)
  if [[ -n $mysqldump_extra_opts ]]; then
    local -a extra
    read -r -a extra <<< "$mysqldump_extra_opts"
    base+=("${extra[@]}")
  fi

  if is_dry_run; then
    info "[dry-run] would export '${export_db_name}' (${db_export_method}) to ${out} with ${#ignore_opts[@]} table(s) data-excluded, then back up, drop and re-import '${import_db_name}'"
    return 0
  fi
  info "Exporting '${export_db_name}' (${db_export_method} method) to ${out}"
  if ((${#ignore_opts[@]} == 0)); then
    remote_dump "${base[@]}" "$export_db_name" | maybe_pv > "$out"
  else
    {
      remote_dump "${base[@]}" --no-data --skip-triggers "$export_db_name" || exit 1
      remote_dump "${base[@]}" --no-create-info "${ignore_opts[@]}" "$export_db_name" || exit 1
    } | maybe_pv > "$out"
  fi || { error "Database export failed"; rm -f -- "$out"; return 1; }
  [[ -s $out ]] || { error "The export produced an empty file: ${out}"; return 1; }
  ok "Export complete: ${out} ($(($(file_size "$out") / 1024 / 1024))MB)"
}
