#!/usr/bin/env bash
# steps/local-hardening.sh — settings that make the copy behave like a local/dev site.

step_local_hardening() {
  [[ -f $local_web_root/wp-config.php ]] || { error "wp-config.php not found in ${local_web_root}"; return 1; }
  local p dbg=false email
  if [[ -n $wp_environment_type ]]; then
    wpcli config set WP_ENVIRONMENT_TYPE "$wp_environment_type" --quiet || return 1
  fi
  is_true "$wp_debug" && dbg=true
  wpcli config set WP_DEBUG "$dbg" --raw --quiet || return 1
  if is_true "$wp_discourage_search_engines"; then
    wpcli option update blog_public 0 --quiet || return 1
  fi
  while IFS= read -r p; do
    [[ -n $p ]] || continue
    if wpq plugin is-installed "$p" >/dev/null 2>&1; then
      info "Deactivating plugin: ${p}"
      wpcli plugin deactivate "$p" --quiet || warn "Could not deactivate ${p}"
    fi
  done <<< "$(read_list_file "$host_plugins_deactivate_file_path")"
  if [[ -n $wp_local_admin_user ]]; then
    [[ -n $wp_local_admin_pass ]] || { error "wp_local_admin_pass is required when wp_local_admin_user is set"; return 1; }
    email=$wp_local_admin_email
    [[ -n $email ]] || email="${wp_local_admin_user}@${local_domain}"
    if wpq user get "$wp_local_admin_user" --field=ID >/dev/null 2>&1; then
      info "Updating local admin user '${wp_local_admin_user}'"
      wpcli user update "$wp_local_admin_user" --user_pass="$wp_local_admin_pass" --role=administrator --quiet || return 1
    else
      info "Creating local admin user '${wp_local_admin_user}'"
      wpcli user create "$wp_local_admin_user" "$email" --role=administrator --user_pass="$wp_local_admin_pass" --quiet || return 1
    fi
    if [[ ${MULTISITE:-false} == true ]]; then
      wpcli super-admin add "$wp_local_admin_user" --quiet || warn "Could not grant super-admin"
    fi
  fi
  return 0
}
