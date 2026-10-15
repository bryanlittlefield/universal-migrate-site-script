#!/usr/bin/env bash
# lib/db.sh — MySQL/MariaDB helpers for export, import and verification.

# db_write_cnf NAME USER PASS HOST PORT — write a client option file (mode 600)
# so passwords never go on a command line. Prints the path.
db_write_cnf() {
  local f="$TMP_DIR/$1.cnf"
  printf '[client]\nuser=%s\npassword=%s\nhost=%s\nport=%s\n' \
    "$(cnf_quote "$2")" "$(cnf_quote "$3")" "$4" "$5" > "$f" || return 1
  chmod 600 "$f"
  printf '%s' "$f"
}

# db_client_flags VERSION_STRING HOST [OVERRIDE]
# Flags that make the mysql/mysqldump client cooperate with the server:
#   - MariaDB clients (11.4+) verify SSL by default and fail against loopback -> --skip-ssl
#   - MySQL 8 clients  -> --ssl-mode=DISABLED on loopback, PREFERRED elsewhere
db_client_flags() {
  local ver=${1-} host=${2-} override=${3-} loopback=false re
  if [[ -n $override ]]; then printf '%s' "$override"; return 0; fi
  case $host in 127.0.0.1|localhost|::1) loopback=true ;; esac
  re='Distrib 5\.[56]'
  if [[ $ver == *MariaDB* ]] || [[ $ver =~ $re ]]; then
    [[ $loopback == true ]] && printf -- '--skip-ssl'
  elif [[ -n $ver ]]; then
    if [[ $loopback == true ]]; then printf -- '--ssl-mode=DISABLED'; else printf -- '--ssl-mode=PREFERRED'; fi
  fi
  return 0
}

# db_dump_compat_flags VERSION_STRING — MySQL 8/9 mysqldump against older
# servers needs --column-statistics=0.
db_dump_compat_flags() {
  local ver=${1-} re='(Ver|Distrib) (8|9)\.'
  if [[ $ver != *MariaDB* && $ver =~ $re ]]; then printf -- '--column-statistics=0'; fi
  return 0
}

# should_fix_collation SERVER_VERSION — MySQL 8 collations (utf8mb4_0900_*)
# do not exist on MariaDB or MySQL < 8.
should_fix_collation() {
  local ver=${1-} re='^[0-7]\.'
  [[ $ver == *MariaDB* ]] && return 0
  [[ $ver =~ $re ]] && return 0
  return 1
}

# dump_filter — sanitise a dump on the way through:
#   strip DEFINER clauses (the user rarely exists locally), drop the MariaDB
#   "sandbox mode" line that older servers reject, optionally map collations.
dump_filter() {
  local -a expr=(
    -e 's/DEFINER=`[^`]*`@`[^`]*` *//g'
    -e 's/ SQL SECURITY DEFINER//g'
    -e '/enable the sandbox mode/d'
  )
  if [[ ${FIX_COLLATION:-false} == true ]]; then
    expr+=(-e 's/utf8mb4_0900_ai_ci/utf8mb4_unicode_ci/g'
           -e 's/utf8mb4_0900_as_cs/utf8mb4_bin/g'
           -e 's/utf8mb4_0900_bin/utf8mb4_bin/g')
  fi
  sed "${expr[@]}"
}

# resolve_table_patterns TABLES PATTERNS — both newline-separated; prints the
# tables matching any pattern (shell wildcards), in table order.
resolve_table_patterns() {
  local tables=$1 patterns=$2 t p
  while IFS= read -r t; do
    [[ -z $t ]] && continue
    while IFS= read -r p; do
      [[ -z $p ]] && continue
      # shellcheck disable=SC2053  # unquoted on purpose: glob match
      if [[ $t == $p ]]; then printf '%s\n' "$t"; break; fi
    done <<< "$patterns"
  done <<< "$tables"
}

# ---------------------------------------------------------------- local side

db_init_local() {
  [[ ${DB_LOCAL_READY:-false} == true ]] && return 0
  LOCAL_CNF=$(db_write_cnf local "$import_db_user" "$import_db_pass" "$import_db_host" "$import_db_port") || return 1
  local cver dver
  cver=$(mysql --version 2>/dev/null || true)
  dver=$(mysqldump --version 2>/dev/null || true)
  read -r -a LOCAL_CLIENT_FLAGS <<< "$(db_client_flags "$cver" "$import_db_host" "$import_db_ssl_flag")"
  read -r -a LOCAL_DUMP_FLAGS <<< "$(db_client_flags "$dver" "$import_db_host" "$import_db_ssl_flag") $(db_dump_compat_flags "$dver")"
  DB_LOCAL_READY=true
}

mysql_local() {
  mysql --defaults-extra-file="$LOCAL_CNF" ${LOCAL_CLIENT_FLAGS[@]+"${LOCAL_CLIENT_FLAGS[@]}"} "$@"
}

mysqldump_local() {
  mysqldump --defaults-extra-file="$LOCAL_CNF" ${LOCAL_DUMP_FLAGS[@]+"${LOCAL_DUMP_FLAGS[@]}"} "$@"
}

local_server_version() { mysql_local -N -B -e 'SELECT VERSION()'; }

local_db_exists() {
  [[ -n $(mysql_local -N -B -e "SHOW DATABASES LIKE '${import_db_name}'" 2>/dev/null) ]]
}

local_table_count() {
  mysql_local -N -B -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='${import_db_name}'"
}

local_tables() { mysql_local -N -B -e 'SHOW TABLES' "$import_db_name"; }

# dump_local_tables FILE TABLE... — DROP/CREATE/INSERT for the given local
# tables, so they can be put back after the import (db_preserve_tables).
dump_local_tables() {
  local file=$1
  shift
  printf -- '-- universal-migrate-site-script: preserved local tables: %s\nSET FOREIGN_KEY_CHECKS=0;\n' "$*" > "$file" || return 1
  mysqldump_local --quick --single-transaction --no-tablespaces --add-drop-table "$import_db_name" "$@" >> "$file" || return 1
  printf 'SET FOREIGN_KEY_CHECKS=1;\n' >> "$file"
}

restore_preserved_tables() { mysql_local "$import_db_name" < "$1"; }

drop_all_local_tables() {
  local sql
  sql=$(mysql_local -N -B -e "SELECT CONCAT('DROP ', IF(table_type='VIEW','VIEW','TABLE'), ' IF EXISTS \`', table_name, '\`;') FROM information_schema.tables WHERE table_schema='${import_db_name}'") || return 1
  if [[ -z $sql ]]; then info "Local database is empty; nothing to drop."; return 0; fi
  printf 'SET FOREIGN_KEY_CHECKS=0;\n%s\nSET FOREIGN_KEY_CHECKS=1;\n' "$sql" | mysql_local "$import_db_name"
}

backup_local_db() {
  local f=$local_db_backup_filename
  [[ -n $f ]] || f="$dump_dir/${import_db_name}-backup-${RUN_TAG}.sql.gz"
  info "Backing up the current local database '${import_db_name}' to ${f}"
  if [[ $f == *.gz ]]; then
    mysqldump_local --quick --single-transaction --no-tablespaces "$import_db_name" | gzip -c > "$f"
  else
    mysqldump_local --quick --single-transaction --no-tablespaces "$import_db_name" > "$f"
  fi || { error "Local database backup failed"; return 1; }
  LOCAL_DB_BACKUP_FILE=$f
}

# import_dump_file FILE — stream the dump into the local database with the
# usual bulk-load settings (session level only; no SUPER privilege needed).
import_dump_file() {
  local file=$1 size
  size=$(file_size "$file")
  {
    printf 'SET autocommit=0;\nSET unique_checks=0;\nSET foreign_key_checks=0;\n'
    cat "$file"
    printf '\nSET foreign_key_checks=1;\nSET unique_checks=1;\nCOMMIT;\n'
  } | maybe_pv -s "$size" | mysql_local --max-allowed-packet=1073741824 "$import_db_name"
}

# --------------------------------------------------------------- remote side

db_init_remote() {
  [[ ${DB_REMOTE_READY:-false} == true ]] && return 0
  if [[ $db_export_method == tunnel ]]; then
    open_tunnel || return 1
    TUNNEL_CNF=$(db_write_cnf tunnel "$export_db_user" "$export_db_pass" 127.0.0.1 "$TUNNEL_PORT") || return 1
    local cver dver
    cver=$(mysql --version 2>/dev/null || true)
    dver=$(mysqldump --version 2>/dev/null || true)
    read -r -a TUNNEL_CLIENT_FLAGS <<< "$(db_client_flags "$cver" 127.0.0.1 "$export_db_ssl_flag")"
    read -r -a TUNNEL_DUMP_FLAGS <<< "$(db_client_flags "$dver" 127.0.0.1 "$export_db_ssl_flag") $(db_dump_compat_flags "$dver")"
  else
    local mver dver
    mver=$(ssh_run 'mysql --version' 2>/dev/null || true)
    dver=$(ssh_run 'mysqldump --version' 2>/dev/null || true)
    if [[ -z $dver ]]; then
      error "mysqldump was not found on the remote server. Use db_export_method=tunnel instead."
      return 1
    fi
    REMOTE_CLIENT_FLAGS=$(db_client_flags "$mver" "$export_db_host" "$export_db_ssl_flag")
    REMOTE_DUMP_FLAGS="$(db_client_flags "$dver" "$export_db_host" "$export_db_ssl_flag") $(db_dump_compat_flags "$dver")"
    REMOTE_COMPRESS=false
    case $(to_lower "$db_transfer_compress") in
      true) REMOTE_COMPRESS=true ;;
      auto) have_cmd gunzip && ssh_run 'command -v gzip >/dev/null 2>&1' && REMOTE_COMPRESS=true ;;
    esac
  fi
  DB_REMOTE_READY=true
}

db_teardown_remote() {
  close_tunnel
  DB_REMOTE_READY=false
}

# remote_query SQL — rows from the remote database, tab separated, no header.
remote_query() {
  if [[ $db_export_method == tunnel ]]; then
    mysql --defaults-extra-file="$TUNNEL_CNF" ${TUNNEL_CLIENT_FLAGS[@]+"${TUNNEL_CLIENT_FLAGS[@]}"} \
      -N -B -e "$1" "$export_db_name"
  else
    ssh_run_secret "$export_db_pass" "mysql ${REMOTE_CLIENT_FLAGS} -u $(shell_quote "$export_db_user") \
      -h $(shell_quote "$export_db_host") -P $(shell_quote "$export_db_port") -N -B \
      -e $(shell_quote "$1") $(shell_quote "$export_db_name")"
  fi
}

# remote_dump MYSQLDUMP_ARGS... — filtered SQL on stdout, via whichever method.
remote_dump() {
  if [[ $db_export_method == tunnel ]]; then
    mysqldump --defaults-extra-file="$TUNNEL_CNF" ${TUNNEL_DUMP_FLAGS[@]+"${TUNNEL_DUMP_FLAGS[@]}"} "$@" | dump_filter
  else
    local cmd a
    cmd="mysqldump ${REMOTE_DUMP_FLAGS} -u $(shell_quote "$export_db_user") -h $(shell_quote "$export_db_host") -P $(shell_quote "$export_db_port")"
    for a in "$@"; do cmd+=" $(shell_quote "$a")"; done
    if [[ ${REMOTE_COMPRESS:-false} == true ]]; then
      ssh_run_secret "$export_db_pass" "$cmd | gzip -c" | gunzip -c | dump_filter
    else
      ssh_run_secret "$export_db_pass" "$cmd" | dump_filter
    fi
  fi
}
