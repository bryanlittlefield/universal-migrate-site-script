#!/usr/bin/env bash
# lib/util.sh — small, dependency-free helpers shared by every other file.
# Everything here must work on bash 3.2 (macOS) as well as bash 5 (Linux).

to_lower() { printf '%s' "$*" | tr '[:upper:]' '[:lower:]'; }

# is_true VALUE — true for true/1/yes/y/on (case-insensitive).
is_true() {
  case "$(to_lower "${1:-}")" in
    true|1|yes|y|on) return 0 ;;
    *) return 1 ;;
  esac
}

have_cmd() { command -v "$1" >/dev/null 2>&1; }

is_dry_run() { is_true "${DRY_RUN:-false}"; }

# trim STRING — strip leading/trailing whitespace.
trim() {
  local s=${1-}
  s=${s#"${s%%[![:space:]]*}"}
  s=${s%"${s##*[![:space:]]}"}
  printf '%s' "$s"
}

# normalize_dir PATH — remove trailing slashes ("/" stays "/").
normalize_dir() {
  local p=${1-}
  while [[ ${#p} -gt 1 && $p == */ ]]; do p=${p%/}; done
  printf '%s' "$p"
}

# normalize_domain VALUE — strip scheme, path and trailing slash.
normalize_domain() {
  local d=${1-}
  d=${d#http://}
  d=${d#https://}
  d=${d%%/*}
  printf '%s' "$d"
}

# shell_quote STRING — quote for a remote POSIX shell. Arguments made only of
# safe characters are left bare so logs stay readable.
shell_quote() {
  local s=${1-}
  if [[ -z $s ]]; then printf "''"; return 0; fi
  case $s in
    *[!A-Za-z0-9_./:=@%+,-]*) printf "'%s'" "$(printf '%s' "$s" | sed "s/'/'\\\\''/g")" ;;
    *) printf '%s' "$s" ;;
  esac
}

# cnf_quote STRING — double-quote a value for a MySQL option file.
cnf_quote() {
  printf '"%s"' "$(printf '%s' "${1-}" | sed 's/\\/\\\\/g; s/"/\\"/g')"
}

# in_csv NEEDLE CSV — is NEEDLE one of the comma-separated items?
in_csv() {
  local needle=$1 list=${2-}
  [[ ",${list}," == *",${needle},"* ]]
}

# read_list_file FILE — print non-blank, non-comment lines, trimmed.
# The legacy sentinel "no_tables_ignored" from the old script is ignored.
read_list_file() {
  local f=${1-} line
  [[ -n $f && -f $f ]] || return 0
  while IFS= read -r line || [[ -n $line ]]; do
    line=$(trim "$line")
    [[ -z $line || $line == \#* ]] && continue
    [[ $line == "no_tables_ignored" ]] && continue
    printf '%s\n' "$line"
  done < "$f"
}

# split_list "a, b c" — comma- and/or whitespace-separated list, one item per line.
split_list() {
  printf '%s' "${1-}" | tr ', ' '\n\n' | sed '/^$/d'
}

# sed_inplace ARGS... — portable `sed -i` (GNU and BSD).
sed_inplace() {
  if sed --version >/dev/null 2>&1; then sed -i "$@"; else sed -i '' "$@"; fi
}

file_size() { wc -c < "$1" | tr -d ' '; }

fmt_duration() {
  local s=${1:-0}
  printf '%dm %02ds' $((s / 60)) $((s % 60))
}

now_tag() { date +'%Y-%m-%d_%H-%M-%S'; }

mask() { if [[ -n ${1-} ]]; then printf '********'; else printf '(empty)'; fi; }

# redact STRING — replace known secrets with *** before printing/logging.
redact() {
  local s=$1 v
  for v in "${import_db_pass-}" "${export_db_pass-}" "${remote_ssh_pass-}" "${wp_local_admin_pass-}"; do
    [[ -n $v ]] && s=${s//"$v"/***}
  done
  printf '%s' "$s"
}

# run_cmd CMD ARGS... — run a command, or print it when --dry-run is active.
run_cmd() {
  if is_dry_run; then
    printf '%s[dry-run]%s %s\n' "${C_GREY-}" "${C_RESET-}" "$(redact "$(printf '%q ' "$@")")"
    return 0
  fi
  "$@"
}

# set_env_kv FILE KEY VALUE — set KEY=VALUE in a dotenv file (replace or append).
set_env_kv() {
  local file=$1 key=$2 value=$3 tmp
  case $value in
    *[[:space:]\#\"\'\$]*) value="\"$(printf '%s' "$value" | sed 's/\\/\\\\/g; s/"/\\"/g')\"" ;;
  esac
  tmp=$(mktemp "${TMPDIR:-/tmp}/ums-env.XXXXXX") || return 1
  [[ -f $file ]] || : > "$file"
  if grep -qE "^[[:space:]]*(export[[:space:]]+)?${key}=" "$file"; then
    K="$key" V="$value" awk '
      BEGIN { done = 0; k = ENVIRON["K"]; v = ENVIRON["V"] }
      !done && $0 ~ ("^[ \t]*(export[ \t]+)?" k "=") { print k "=" v; done = 1; next }
      { print }' "$file" > "$tmp" || return 1
  else
    {
      cat "$file"
      [[ -s $file && -n $(tail -c 1 "$file") ]] && printf '\n'
      printf '%s=%s\n' "$key" "$value"
    } > "$tmp"
  fi
  cat "$tmp" > "$file" && rm -f "$tmp"
}

# port_in_use HOST PORT — true when something accepts TCP connections there.
port_in_use() { (exec 3<>"/dev/tcp/$1/$2") 2>/dev/null; }

# find_free_port [START] — first free local port at or after START.
find_free_port() {
  local p=${1:-33060} end
  end=$((p + 200))
  while ((p < end)); do
    if ! port_in_use 127.0.0.1 "$p"; then printf '%s' "$p"; return 0; fi
    p=$((p + 1))
  done
  return 1
}

# wait_for_port HOST PORT [TIMEOUT_SECONDS]
wait_for_port() {
  local host=$1 port=$2 timeout=${3:-30} start=$SECONDS
  until port_in_use "$host" "$port"; do
    ((SECONDS - start >= timeout)) && return 1
    sleep 1
  done
}

# uploads_only_filters REL_PATH — rsync include/exclude args (one per line)
# that transfer only REL_PATH and its parents.
uploads_only_filters() {
  local rel=${1#/} acc="" part
  rel=${rel%/}
  local IFS=/
  for part in $rel; do
    acc="$acc/$part"
    printf -- '--include=%s/\n' "$acc"
  done
  printf -- '--include=%s/**\n--exclude=*\n' "$acc"
}

# maybe_pv ARGS... — pipe through pv when available and output is interactive.
maybe_pv() {
  if have_cmd pv && ! is_true "${plain_output:-false}" && [[ ${STDOUT_IS_TTY:-false} == true ]]; then
    pv "$@"
  else
    cat
  fi
}
