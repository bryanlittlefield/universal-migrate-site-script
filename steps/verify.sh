#!/usr/bin/env bash
# steps/verify.sh — sanity-check the result. Warnings do not fail the step;
# only things that are definitely broken do.

step_verify() {
  local fails=0 ver home code url
  case $platform in
    wordpress)
      if ver=$(wpq core version 2>/dev/null); then
        ok "WordPress ${ver} loads"
      else
        error "WP-CLI cannot load the site (wp core version failed)"
        fails=1
      fi
      if home=$(wpq option get home 2>/dev/null); then
        if [[ $home == *"$local_domain"* ]]; then ok "home option: ${home}"; else warn "home option is '${home}', expected it to contain '${local_domain}'"; fi
      fi
      if is_true "$verify_db_check"; then
        wpq db check >/dev/null 2>&1 && ok "wp db check passed" || warn "wp db check reported problems"
      fi
      ;;
    laravel)
      if run_cmd php "$local_web_root/artisan" --version >/dev/null 2>&1; then
        ok "artisan runs"
      else
        error "artisan --version failed"
        fails=1
      fi
      ;;
  esac
  if [[ ${DB_MIGRATED:-false} == true && -n ${REMOTE_TABLE_COUNT:-} ]]; then
    if [[ ${LOCAL_TABLE_COUNT:-?} == "$REMOTE_TABLE_COUNT" ]]; then
      ok "Table count matches: ${LOCAL_TABLE_COUNT}"
    else
      warn "Table count differs: remote ${REMOTE_TABLE_COUNT}, local ${LOCAL_TABLE_COUNT:-?}"
    fi
  fi
  if is_true "$verify_http" && have_cmd curl && [[ -n $local_domain ]]; then
    url="${local_scheme}://${local_domain}/"
    code=$(curl -ksS -o /dev/null -w '%{http_code}' --max-time 20 "$url" 2>/dev/null || true)
    case $code in
      200|301|302) ok "HTTP ${code} from ${url}" ;;
      *) warn "HTTP check of ${url} returned '${code:-no response}' (the domain may not resolve from this machine)" ;;
    esac
  fi
  return "$fails"
}
