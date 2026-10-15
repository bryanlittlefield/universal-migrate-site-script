#!/usr/bin/env bats
load test_helper

setup() { load_libs; }

@test "db_client_flags: MariaDB client on loopback -> --skip-ssl" {
  [ "$(db_client_flags 'mysql  Ver 15.1 Distrib 10.11.6-MariaDB' 127.0.0.1)" = "--skip-ssl" ]
  [ "$(db_client_flags 'Distrib 10.11.6-MariaDB' localhost)" = "--skip-ssl" ]
}

@test "db_client_flags: MariaDB client on a remote host -> nothing" {
  [ -z "$(db_client_flags 'Distrib 10.11.6-MariaDB' db.example.com)" ]
}

@test "db_client_flags: MySQL 8 client -> ssl-mode DISABLED on loopback, PREFERRED elsewhere" {
  [ "$(db_client_flags 'mysql  Ver 8.0.36 for Linux' localhost)" = "--ssl-mode=DISABLED" ]
  [ "$(db_client_flags 'mysql  Ver 8.0.36 for Linux' db.example.com)" = "--ssl-mode=PREFERRED" ]
}

@test "db_client_flags: MySQL 5.6 client -> --skip-ssl on loopback" {
  [ "$(db_client_flags 'mysql  Ver 14.14 Distrib 5.6.51' 127.0.0.1)" = "--skip-ssl" ]
}

@test "db_client_flags: explicit override wins, empty version gives nothing" {
  [ "$(db_client_flags 'x' 127.0.0.1 '--ssl=0')" = "--ssl=0" ]
  [ -z "$(db_client_flags '' 127.0.0.1)" ]
}

@test "db_dump_compat_flags only for MySQL 8/9 mysqldump" {
  [ "$(db_dump_compat_flags 'mysqldump  Ver 8.0.36 for Linux')" = "--column-statistics=0" ]
  [ -z "$(db_dump_compat_flags 'mysqldump  Ver 10.19 Distrib 10.6.12-MariaDB')" ]
  [ -z "$(db_dump_compat_flags 'mysqldump  Ver 10.13 Distrib 5.7.42')" ]
}

@test "should_fix_collation for MariaDB and MySQL < 8" {
  should_fix_collation '10.6.12-MariaDB'
  should_fix_collation '5.7.42-log'
  ! should_fix_collation '8.0.36'
  ! should_fix_collation '9.1.0'
}

@test "dump_filter strips DEFINER, sandbox line and maps collations when asked" {
  FIX_COLLATION=true
  run dump_filter < "$FIXTURES/dump.sql"
  [ "$status" -eq 0 ]
  [[ $output != *DEFINER* ]]
  [[ $output != *"sandbox mode"* ]]
  [[ $output != *utf8mb4_0900_ai_ci* ]]
  [[ $output == *utf8mb4_unicode_ci* ]]
  [[ $output == *"/*!50013 */"* ]]
  [[ $output == *"/*!50017 */"* ]]
  [[ $output == *"CREATE TABLE \`wp_options\`"* ]]
}

@test "dump_filter leaves collations alone by default" {
  FIX_COLLATION=false
  run dump_filter < "$FIXTURES/dump.sql"
  [[ $output == *utf8mb4_0900_ai_ci* ]]
  [[ $output != *DEFINER* ]]
}

@test "resolve_table_patterns expands wildcards against the table list" {
  run resolve_table_patterns $'wp_posts\nwp_actionscheduler_actions\nwp_actionscheduler_logs\nwp_wfhits' $'*_actionscheduler_*\nwp_wfhits\nmissing'
  [ "$output" = $'wp_actionscheduler_actions\nwp_actionscheduler_logs\nwp_wfhits' ]
}
