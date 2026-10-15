#!/usr/bin/env bats
# End-to-end runs of migrate.sh against stubbed ssh/rsync/mysql/wp/php binaries.
load test_helper

setup() {
  T=$(new_tmp)
  export STUB_LOG="$T/stub.log" STUB_STATE="$T/state" STUB_FIXTURES="$FIXTURES" STUB_IMPORT_CAPTURE="$T/import.sql"
  mkdir -p "$STUB_STATE" "$T/logs" "$T/dumps"
  export PATH="$STUB_BIN:$PATH"
  printf '# data excluded\n*_actionscheduler_*\nwp_wfhits\nmissing_table\n' > "$T/db-exclude.txt"
  unset STUB_RSYNC_EXIT
}

teardown() {
  [[ -f $STUB_STATE/tunnel.pid ]] && kill "$(cat "$STUB_STATE/tunnel.pid")" 2>/dev/null
  rm -rf "$T"
}

make_wp_site() {
  mkdir -p "$T/www/wp-content/mu-plugins/wpengine-common" "$T/www/wp-includes"
  : > "$T/www/wp-content/mu-plugins/wpengine-common/plugin.php"
  : > "$T/www/wp-content/mu-plugins/keep-me.php"
  : > "$T/www/wp-content/object-cache.php"
  cat > "$T/www/wp-config.php" <<'CFG'
<?php
define( 'DB_NAME', 'olddb' );
define( 'WP_CACHE', true );
define( 'WPE_APIKEY', 'abc' );
define( 'PWP_NAME', 'site' );
$memcached_servers = array( '127.0.0.1:11211' );
define( 'DB_HOST_SLAVE', 'x' );

define( 'WP_DEBUG', false );
umask(0002);
/* That's all, stop editing! */
CFG
}

make_laravel_site() {
  mkdir -p "$T/www"
  : > "$T/www/artisan"
  printf 'APP_NAME=Demo\nAPP_URL=https://old.example.com\nAPP_KEY=\nDB_DATABASE=olddb\n' > "$T/www/.env"
}

# write_env PLATFORM METHOD [extra lines...]
write_env() {
  local platform=$1 method=$2
  shift 2
  {
    cat <<ENV
remote_ssh_host='remote.example.com'
remote_ssh_user='deploy'
remote_ssh_port='2222'
remote_ssh_web_root='/var/www/html/'
remote_domain='https://old.example.com/'
export_db_name='remotedb'
export_db_user='ru'
export_db_pass='pa\$s wo#rd'
db_export_method='$method'
local_web_root='$T/www/'
local_domain='site.local'
local_scheme='http'
import_db_name='localdb'
import_db_user='root'
import_db_pass='secret'
platform='$platform'
log_dir='$T/logs'
dump_dir='$T/dumps'
db_exclude_tables_file_path='$T/db-exclude.txt'
ENV
    printf '%s\n' "$@"
  } > "$T/test.env"
}

migrate() { bash "$REPO_ROOT/migrate.sh" --env "$T/test.env" --plain "$@"; }

@test "wordpress end-to-end with the remote export method" {
  make_wp_site
  write_env wordpress remote
  run migrate --yes
  echo "$output"
  [ "$status" -eq 0 ]
  [[ $output == *"Migration finished"* ]]

  # file sync
  grep -q 'rsync .*--exclude-from=.*rsync-exclude.txt' "$STUB_LOG"
  grep -q "rsync .* deploy@remote.example.com:/var/www/html/ $T/www/" "$STUB_LOG"
  grep -q "rsync .*-e ssh -p 2222 " "$STUB_LOG"
  grep -q 'rsync .*--exclude=/.maintenance' "$STUB_LOG"

  # database export over ssh: MariaDB flags, password not on the command line, excludes resolved
  grep -q 'ssh .*mysqldump --skip-ssl' "$STUB_LOG"
  grep -q 'MYSQL_PWD="$(cat)" mysqldump' "$STUB_LOG"
  ! grep -q 'wo#rd' "$STUB_LOG"
  grep -q -- '--ignore-table=remotedb.wp_actionscheduler_actions' "$STUB_LOG"
  grep -q -- '--ignore-table=remotedb.wp_wfhits' "$STUB_LOG"
  grep -q -- '--no-data --skip-triggers' "$STUB_LOG"
  grep -q '| gzip -c' "$STUB_LOG"
  [[ $output == *"has no such table"* ]]
  ls "$T/dumps"/remotedb-*.sql >/dev/null
  [ -s "$T/dumps"/remotedb-*.sql ]

  # local side: MySQL 8 client flags, backup, drop, filtered import with bulk settings
  grep -q 'mysql --defaults-extra-file=.* --ssl-mode=DISABLED' "$STUB_LOG"
  ls "$T/dumps"/localdb-backup-*.sql.gz >/dev/null
  grep -q 'DROP TABLE IF EXISTS `wp_old`' "$T/import.sql"
  grep -q '^SET autocommit=0;' "$T/import.sql"
  grep -q 'utf8mb4_unicode_ci' "$T/import.sql"
  ! grep -q 'DEFINER' "$T/import.sql"
  ! grep -q 'sandbox mode' "$T/import.sql"
  grep -q '^COMMIT;' "$T/import.sql"

  # wordpress config + search-replace (www variant first, then domain, then scheme)
  grep -q 'wp .*config set DB_NAME localdb' "$STUB_LOG"
  grep -q 'wp .*config set WP_HOME http://site.local' "$STUB_LOG"
  grep -q 'wp .*search-replace .*--skip-tables=.*\*_users.* www.old.example.com site.local' "$STUB_LOG"
  grep -q 'wp .*search-replace .* old.example.com site.local' "$STUB_LOG"
  grep -q 'wp .*search-replace .* https://site.local http://site.local' "$STUB_LOG"

  # host cleanup
  ! grep -q 'WPE_APIKEY' "$T/www/wp-config.php"
  ! grep -q 'PWP_NAME' "$T/www/wp-config.php"
  ! grep -q 'memcached_servers' "$T/www/wp-config.php"
  ! grep -q 'umask' "$T/www/wp-config.php"
  grep -q "DB_NAME" "$T/www/wp-config.php"
  grep -q "WP_DEBUG" "$T/www/wp-config.php"
  ls "$T/www"/wp-config.php.bak-* >/dev/null
  [ ! -e "$T/www/wp-content/mu-plugins/wpengine-common" ]
  [ -e "$T/www/wp-content/mu-plugins/keep-me.php" ]
  [ ! -e "$T/www/wp-content/object-cache.php" ]

  # hardening, cache, verify, maintenance
  grep -q 'wp .*config set WP_ENVIRONMENT_TYPE local' "$STUB_LOG"
  grep -q 'wp .*config set WP_DEBUG true --raw' "$STUB_LOG"
  grep -q 'wp .*option update blog_public 0' "$STUB_LOG"
  grep -q 'wp .*rewrite flush' "$STUB_LOG"
  grep -q 'wp .*cache flush' "$STUB_LOG"
  [[ $output == *"Table count matches: 5"* ]]
  [[ $output == *"HTTP 200 from http://site.local/"* ]]
  [ ! -e "$T/www/.maintenance" ]
  grep -q 'Maintenance mode enabled' "$T"/logs/migrate-*.log

  # opt-in step skipped, report written
  [[ $output == *"Install Kinsta MU plugins"*"opt-in"* ]]
  ls "$T/logs"/migrate-report-*.txt >/dev/null
  grep -q '\[OK\] Sync files from remote' "$T"/logs/migrate-report-*.txt
}

@test "wordpress end-to-end with the tunnel export method" {
  command -v python3 >/dev/null || skip "python3 needed for the fake tunnel listener"
  make_wp_site
  write_env wordpress tunnel
  run migrate --yes
  echo "$output"
  [ "$status" -eq 0 ]
  grep -q 'ssh .* -f -N -M -S .* -L 127.0.0.1:[0-9]*:127.0.0.1:3306 deploy@remote.example.com' "$STUB_LOG"
  grep -q 'ssh -S .* -O exit deploy@remote.example.com' "$STUB_LOG"
  grep -q 'mysqldump --defaults-extra-file=.* --ssl-mode=DISABLED --column-statistics=0 .* --ignore-table=remotedb.wp_wfhits' "$STUB_LOG"
  grep -q 'utf8mb4_unicode_ci' "$T/import.sql"
  [ ! -e "$STUB_STATE/tunnel.pid" ]
}

@test "laravel end-to-end" {
  make_laravel_site
  write_env laravel remote
  run migrate --yes
  echo "$output"
  [ "$status" -eq 0 ]
  grep -q "php $T/www/artisan down --retry=60" "$STUB_LOG"
  grep -q "php $T/www/artisan optimize:clear" "$STUB_LOG"
  grep -q "php $T/www/artisan up" "$STUB_LOG"
  grep -q "php $T/www/artisan key:generate --force" "$STUB_LOG"
  grep -q '^APP_URL=http://site.local$' "$T/www/.env"
  grep -q '^APP_ENV=local$' "$T/www/.env"
  grep -q '^DB_DATABASE=localdb$' "$T/www/.env"
  grep -q '^DB_PASSWORD=secret$' "$T/www/.env"
  grep -q '^APP_NAME=Demo$' "$T/www/.env"
  ! grep -q '^wp ' "$STUB_LOG"
  [[ $output == *"Remove WP Engine config"*"platform is laravel"* ]]
}

@test "--dry-run changes nothing" {
  make_wp_site
  write_env wordpress remote
  run migrate --yes --dry-run
  echo "$output"
  [ "$status" -eq 0 ]
  [[ $output == *"DRY RUN"* ]]
  grep -q 'rsync .*--dry-run' "$STUB_LOG"
  [ ! -e "$T/import.sql" ]
  ! ls "$T/dumps"/remotedb-*.sql 2>/dev/null
  grep -q 'WPE_APIKEY' "$T/www/wp-config.php"
  [ -e "$T/www/wp-content/object-cache.php" ]
  ! grep -q '^wp .*config set' "$STUB_LOG"
  grep -q '\[dry-run\] wp .*config set DB_PASSWORD \*\*\*' "$T"/logs/migrate-*.log
}

@test "--check runs the preflight and exits" {
  make_wp_site
  write_env wordpress remote
  run migrate --check
  echo "$output"
  [ "$status" -eq 0 ]
  [[ $output == *"Preflight passed"* ]]
  [[ $output == *"SSH to deploy@remote.example.com"* ]]
  [[ $output == *"Disk space"* ]]
  [ ! -e "$T/import.sql" ]
  ! grep -q '^rsync' "$STUB_LOG"
}

@test "a failing rsync stops the run with a non-zero exit" {
  make_wp_site
  write_env wordpress remote
  export STUB_RSYNC_EXIT=12
  run migrate --yes
  echo "$output"
  [ "$status" -eq 1 ]
  [[ $output == *"rsync failed with exit code 12"* ]]
  [[ $output == *"Stopping after failed step 'sync-files'"* ]]
  [ ! -e "$T/import.sql" ]
}

@test "continue_on_error=true carries on after a failure" {
  make_wp_site
  write_env wordpress remote "continue_on_error='true'"
  export STUB_RSYNC_EXIT=12
  run migrate --yes
  echo "$output"
  [ "$status" -eq 1 ]
  [ -e "$T/import.sql" ]
  [[ $output == *"1 failed step(s): sync-files"* ]]
}

@test "clear-web-root is opt-in under --yes and empties the directory including dotfiles" {
  make_wp_site
  : > "$T/www/.htaccess"
  write_env wordpress remote "skip_file_sync='true'" "skip_db_import='true'" "skip_app_config='true'" \
    "skip_host_cleanup='true'" "skip_local_hardening='true'" "skip_cache_refresh='true'" "skip_verify='true'"
  run migrate --yes
  [ "$status" -eq 0 ]
  [[ $output == *"Clear local web root — skipped (opt-in step"* ]]
  [ -e "$T/www/wp-config.php" ]
  run migrate --yes --with clear-web-root
  echo "$output"
  [ "$status" -eq 0 ]
  [[ $output == *"Enable maintenance mode (local site) — skipped (web root was cleared)"* ]]
  [ -z "$(ls -A "$T/www")" ]
  make_wp_site
  run migrate --yes --only clear-web-root
  [ "$status" -eq 0 ]
  [ -z "$(ls -A "$T/www")" ]
}

@test "clear-web-root refuses a top-level directory" {
  write_env wordpress remote "local_web_root='/tmp'"
  run migrate --yes --only clear-web-root --with clear-web-root
  echo "$output"
  [ "$status" -eq 1 ]
  [[ $output == *"Refusing to clear a top-level directory"* ]]
}

@test "unknown step ids, missing env file and bad options are rejected" {
  write_env wordpress remote
  run migrate --skip nope
  [ "$status" -eq 1 ]
  [[ $output == *"Unknown step id 'nope'"* ]]
  run bash "$REPO_ROOT/migrate.sh" --env "$T/missing.env" --plain
  [ "$status" -eq 1 ]
  [[ $output == *"Env file not found"* ]]
  run migrate --bogus
  [ "$status" -eq 2 ]
}

@test "--list-steps and --version" {
  run bash "$REPO_ROOT/migrate.sh" --list-steps
  [ "$status" -eq 0 ]
  [[ $output == *"clear-web-root"*"opt-in"* ]]
  [[ $output == *"maintenance-off"* ]]
  run bash "$REPO_ROOT/migrate.sh" --version
  [[ $output == "universal-migrate-site-script "* ]]
}

@test "skip_migrate_website=true exits before doing anything" {
  write_env wordpress remote "skip_migrate_website='true'"
  run migrate --yes
  [ "$status" -eq 0 ]
  [[ $output == *"nothing to do"* ]]
  [ ! -s "$STUB_LOG" ]
}

@test "legacy .env: db_ssh_tunnels=false selects the remote method and old skip vars work" {
  make_wp_site
  write_env wordpress "" "db_ssh_tunnels='false'" "skip_file_sync='true'" "skip_db_import='true'"
  sed -i.bak "/^db_export_method=/d" "$T/test.env"
  run migrate --yes
  echo "$output"
  [ "$status" -eq 0 ]
  [[ $output == *"[remote]"* ]]
  [[ $output == *"Sync files from remote — skipped (skip_file_sync=true)"* ]]
  [[ $output == *"Migrate database — skipped (skip_db_import=true)"* ]]
  ! grep -q '^rsync' "$STUB_LOG"
}

@test "no TTY and no --yes refuses to start" {
  make_wp_site
  write_env wordpress remote
  run migrate </dev/null
  [ "$status" -eq 0 ]
  [[ $output == *"No terminal to answer"* ]]
  [[ $output == *"Aborted"* ]]
  ! grep -q '^rsync' "$STUB_LOG"
}
