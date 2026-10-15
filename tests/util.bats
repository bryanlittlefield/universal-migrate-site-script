#!/usr/bin/env bats
load test_helper

setup() { load_libs; T=$(new_tmp); }
teardown() { rm -rf "$T"; }

@test "shell_quote survives a sh -c round trip" {
  local s="it's \$dollar \"dq\" back\\slash \`tick\`"
  run sh -c "printf '%s' $(shell_quote "$s")"
  [ "$status" -eq 0 ]
  [ "$output" = "$s" ]
}

@test "shell_quote of an empty string is ''" {
  [ "$(shell_quote "")" = "''" ]
}

@test "shell_quote leaves safe arguments bare and quotes the rest" {
  [ "$(shell_quote --no-data)" = "--no-data" ]
  [ "$(shell_quote /var/www/html)" = "/var/www/html" ]
  [ "$(shell_quote user@host:3306)" = "user@host:3306" ]
  [ "$(shell_quote 'a b')" = "'a b'" ]
  [ "$(shell_quote 'p$w')" = "'p\$w'" ]
  [ "$(shell_quote "it's")" = "'it'\\''s'" ]
}

@test "cnf_quote escapes quotes and backslashes" {
  [ "$(cnf_quote 'a"b\c')" = '"a\"b\\c"' ]
}

@test "normalize_dir strips trailing slashes but keeps /" {
  [ "$(normalize_dir /var/www/html///)" = "/var/www/html" ]
  [ "$(normalize_dir /)" = "/" ]
  [ "$(normalize_dir "")" = "" ]
}

@test "normalize_domain strips scheme, path and trailing slash" {
  [ "$(normalize_domain 'https://Example.com/path/')" = "Example.com" ]
  [ "$(normalize_domain 'example.com')" = "example.com" ]
}

@test "is_true accepts the usual spellings" {
  is_true TRUE; is_true 1; is_true yes; is_true On
  ! is_true false; ! is_true 0; ! is_true ""
}

@test "trim removes surrounding whitespace" {
  [ "$(trim '  a b  ')" = "a b" ]
}

@test "in_csv finds whole items only" {
  in_csv b a,b,c
  ! in_csv d a,b,c
  ! in_csv a ""
  ! in_csv ab a,b
}

@test "read_list_file skips comments, blanks and the legacy sentinel" {
  printf '# c\n\n  a  \nno_tables_ignored\nb # kept\n' > "$T/l"
  run read_list_file "$T/l"
  [ "$output" = $'a\nb # kept' ]
  run read_list_file "$T/does-not-exist"
  [ "$output" = "" ]
}

@test "set_env_kv replaces, appends and quotes" {
  printf 'APP_URL=https://old\nexport DB_PORT=3306\nAPP_KEY=\n' > "$T/.env"
  set_env_kv "$T/.env" APP_URL http://new
  set_env_kv "$T/.env" DB_PORT 3307
  set_env_kv "$T/.env" DB_PASSWORD 'pa ss#1'
  set_env_kv "$T/.env" NEW_KEY val
  run cat "$T/.env"
  [ "${lines[0]}" = "APP_URL=http://new" ]
  [ "${lines[1]}" = "DB_PORT=3307" ]
  [ "${lines[2]}" = "APP_KEY=" ]
  [ "${lines[3]}" = 'DB_PASSWORD="pa ss#1"' ]
  [ "${lines[4]}" = "NEW_KEY=val" ]
}

@test "set_env_kv adds a newline when the file lacks one" {
  printf 'A=1' > "$T/.env"
  set_env_kv "$T/.env" B 2
  [ "$(cat "$T/.env")" = $'A=1\nB=2' ]
}

@test "uploads_only_filters builds nested include rules" {
  run uploads_only_filters wp-content/uploads
  [ "$output" = $'--include=/wp-content/\n--include=/wp-content/uploads/\n--include=/wp-content/uploads/**\n--exclude=*' ]
}

@test "fmt_duration" {
  [ "$(fmt_duration 125)" = "2m 05s" ]
  [ "$(fmt_duration 0)" = "0m 00s" ]
}

@test "redact masks known secrets" {
  import_db_pass=sekret
  [ "$(redact 'x sekret y')" = "x *** y" ]
}

@test "find_free_port returns a number" {
  p=$(find_free_port 45000)
  [[ $p =~ ^[0-9]+$ ]]
}

@test "run_cmd prints instead of running under --dry-run" {
  DRY_RUN=true
  run run_cmd rm -rf /definitely/not/here
  [ "$status" -eq 0 ]
  [[ $output == *"[dry-run]"* ]]
  [[ $output == *"rm -rf /definitely/not/here"* ]]
}
