#!/usr/bin/env bash
# steps/app-config.sh — point the application at the local database and domain.

step_app_config() {
  case $platform in
    wordpress) wp_app_config ;;
    laravel) laravel_app_config ;;
    *) info "No app-config handling for platform '${platform}'." ;;
  esac
}

wp_app_config() {
  require_vars local_domain remote_domain import_db_name import_db_user || return 1
  [[ -f $local_web_root/wp-config.php ]] || { error "wp-config.php not found in ${local_web_root}"; return 1; }
  local db_host=$import_db_host home skip_tables old new url pair cur
  [[ $import_db_port != 3306 ]] && db_host="${import_db_host}:${import_db_port}"

  info "Writing local database credentials and URLs to wp-config.php"
  wpcli config set DB_NAME "$import_db_name" --quiet || return 1
  wpcli config set DB_USER "$import_db_user" --quiet || return 1
  wpcli config set DB_PASSWORD "$import_db_pass" --quiet || return 1
  wpcli config set DB_HOST "$db_host" --quiet || return 1
  home="${local_scheme}://${local_domain}"
  wpcli config set WP_HOME "$home" --quiet || return 1
  wpcli config set WP_SITEURL "$home" --quiet || return 1

  local -a pairs=()
  local -a sr=(search-replace --recurse-objects --skip-columns=guid --all-tables --report-changed-only)
  skip_tables=$(read_list_file "$wp_search_replace_exclude_file_path" | paste -sd, -)
  [[ -n $skip_tables ]] && sr+=("--skip-tables=${skip_tables}")

  if is_true "$replace_www_variant" && [[ $remote_domain != www.* ]]; then
    pairs+=("www.${remote_domain} ${local_domain}")
  fi
  pairs+=("${remote_domain} ${local_domain}")
  while IFS= read -r pair; do
    [[ -n $pair ]] || continue
    read -r old new _ <<< "$pair"
    [[ -n $old && -n $new ]] && pairs+=("${old} ${new}")
  done <<< "$(read_list_file "$domain_pairs_file_path")"
  if [[ $remote_scheme != "$local_scheme" ]]; then
    pairs+=("${remote_scheme}://${local_domain} ${local_scheme}://${local_domain}")
    pairs+=("${remote_scheme}:\\/\\/${local_domain} ${local_scheme}:\\/\\/${local_domain}")
  fi

  MULTISITE=false
  if wpq --url="$remote_domain" core is-installed --network >/dev/null 2>&1; then
    MULTISITE=true
    info "Multisite network detected"
    sr+=(--network)
  fi
  url=$remote_domain
  for pair in "${pairs[@]}"; do
    old=${pair%% *}
    new=${pair#* }
    info "search-replace: ${old}  ->  ${new}"
    if [[ $MULTISITE == true ]]; then
      wpcli --url="$url" "${sr[@]}" "$old" "$new" || return 1
    else
      wpcli "${sr[@]}" "$old" "$new" || return 1
    fi
    [[ $old == "$remote_domain" ]] && url=$local_domain
  done
  if [[ $MULTISITE == true ]]; then
    cur=$(wpq config get DOMAIN_CURRENT_SITE 2>/dev/null || true)
    if [[ $cur == "$remote_domain" ]]; then
      info "Updating DOMAIN_CURRENT_SITE to ${local_domain}"
      wpcli config set DOMAIN_CURRENT_SITE "$local_domain" --quiet || return 1
    fi
  fi
  return 0
}

laravel_app_config() {
  require_vars local_domain import_db_name import_db_user || return 1
  local envf="$local_web_root/.env"
  if [[ ! -f $envf ]]; then
    if [[ -f $local_web_root/.env.example ]]; then
      info "No .env found; copying .env.example"
      run_cmd cp "$local_web_root/.env.example" "$envf" || return 1
    else
      error "No .env or .env.example in ${local_web_root}"
      return 1
    fi
  fi
  if is_dry_run; then
    info "[dry-run] would update APP_URL, APP_ENV, APP_DEBUG and DB_* in ${envf}"
    return 0
  fi
  set_env_kv "$envf" APP_URL "${local_scheme}://${local_domain}" || return 1
  set_env_kv "$envf" APP_ENV "$laravel_app_env" || return 1
  set_env_kv "$envf" APP_DEBUG "$laravel_app_debug" || return 1
  set_env_kv "$envf" DB_HOST "$import_db_host" || return 1
  set_env_kv "$envf" DB_PORT "$import_db_port" || return 1
  set_env_kv "$envf" DB_DATABASE "$import_db_name" || return 1
  set_env_kv "$envf" DB_USERNAME "$import_db_user" || return 1
  set_env_kv "$envf" DB_PASSWORD "$import_db_pass" || return 1
  if grep -qE '^APP_KEY=[[:space:]]*$' "$envf"; then
    info "APP_KEY is empty; generating one"
    php "$local_web_root/artisan" key:generate --force || warn "key:generate failed; run it manually"
  fi
  ok "Updated ${envf}"
}
