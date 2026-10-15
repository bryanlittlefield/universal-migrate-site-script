#!/usr/bin/env bats
load test_helper

setup() { load_libs; T=$(new_tmp); }
teardown() { rm -rf "$T"; }

@test "defaults fill every variable and legacy db_ssh_tunnels maps to db_export_method" {
  db_ssh_tunnels=false
  apply_legacy_aliases; apply_env_defaults; normalize_env
  [ "$db_export_method" = remote ]
  [ "$remote_ssh_port" = 22 ]
  [ "$export_db_host" = 127.0.0.1 ]
  [ "$platform" = auto ]
}

@test "db_ssh_tunnels=true maps to tunnel; explicit db_export_method wins" {
  db_ssh_tunnels=true; apply_legacy_aliases; [ "$db_export_method" = tunnel ]
  unset db_export_method; db_ssh_tunnels=false; db_export_method=tunnel; apply_legacy_aliases; [ "$db_export_method" = tunnel ]
}

@test "normalize_env cleans paths, domains and case" {
  local_web_root=/var/www/html/; remote_ssh_web_root=/srv/site//
  remote_domain='https://Old.Example.com/'; local_domain='http://site.local'
  platform=WordPress; db_export_method=Remote; sync_mode=Code; rsync_mode=Mirror
  apply_env_defaults; normalize_env
  [ "$local_web_root" = /var/www/html ]
  [ "$remote_ssh_web_root" = /srv/site ]
  [ "$remote_domain" = Old.Example.com ]
  [ "$local_domain" = site.local ]
  [ "$platform" = wordpress ]
  [ "$db_export_method" = remote ]
  [ "$sync_mode" = code ]
  [ "$rsync_mode" = mirror ]
}

@test "normalize_env expands a leading ~ in remote_ssh_key" {
  remote_ssh_key='~/.ssh/dev_id_rsa'
  apply_env_defaults; normalize_env
  [ "$remote_ssh_key" = "$HOME/.ssh/dev_id_rsa" ]
  remote_ssh_key='/abs/key'; normalize_env
  [ "$remote_ssh_key" = "/abs/key" ]
}

@test "validate_env rejects bad values and a missing web root" {
  apply_env_defaults; normalize_env
  run validate_env
  [ "$status" -ne 0 ]
  [[ $output == *"local_web_root is required"* ]]
  local_web_root=/x; platform=drupal; sync_mode=some
  run validate_env
  [ "$status" -ne 0 ]
  [[ $output == *"platform must be"* ]]
  [[ $output == *"sync_mode must be"* ]]
}

@test "require_vars lists what is missing" {
  a=1; b=""
  run require_vars a b c
  [ "$status" -eq 1 ]
  [[ $output == *"b c"* ]]
}

@test "detect_platform finds WordPress and Laravel locally" {
  apply_env_defaults
  mkdir -p "$T/wp"; : > "$T/wp/wp-config.php"
  local_web_root=$T/wp; platform=auto; uploads_rel_path=""
  detect_platform >/dev/null
  [ "$platform" = wordpress ]; [ "$uploads_rel_path" = wp-content/uploads ]
  mkdir -p "$T/lv"; : > "$T/lv/artisan"
  local_web_root=$T/lv; platform=auto; uploads_rel_path=""
  detect_platform >/dev/null
  [ "$platform" = laravel ]; [ "$uploads_rel_path" = storage/app/public ]
}
