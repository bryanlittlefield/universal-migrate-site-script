#!/usr/bin/env bash
# lib/ssh.sh — SSH option building, remote execution and the DB tunnel.

ssh_setup() {
  SSH_OPTS=(-p "$remote_ssh_port" -o ConnectTimeout=20 -o ServerAliveInterval=30
            -o StrictHostKeyChecking="$ssh_strict_host_key")
  [[ $ssh_strict_host_key == no ]] && SSH_OPTS+=(-o UserKnownHostsFile=/dev/null -o LogLevel=ERROR)
  SSH_PREFIX=()
  if [[ -n $remote_ssh_key ]]; then
    SSH_OPTS+=(-i "$remote_ssh_key" -o IdentitiesOnly=yes)
    is_true "${AUTO_CONFIRM:-false}" && SSH_OPTS+=(-o BatchMode=yes)
  elif [[ -n $remote_ssh_pass ]]; then
    export SSHPASS=$remote_ssh_pass
    SSH_PREFIX=(sshpass -e)
    SSH_OPTS+=(-o PreferredAuthentications=password -o PubkeyAuthentication=no)
  fi
  REMOTE="${remote_ssh_user}@${remote_ssh_host}"
  TUNNEL_OPEN=false
  TUNNEL_PORT=""
  TUNNEL_SOCK=""
}

# ssh_run COMMAND — run COMMAND on the remote host. stdin is NOT forwarded
# (-n), so calls inside `while read` loops cannot swallow the loop's input.
ssh_run() {
  ${SSH_PREFIX[@]+"${SSH_PREFIX[@]}"} ssh -n "${SSH_OPTS[@]}" "$REMOTE" "$@"
}

# ssh_run_secret SECRET COMMAND — like ssh_run, but SECRET is delivered on
# stdin and exposed to COMMAND as MYSQL_PWD, so it never appears in `ps`.
ssh_run_secret() {
  local secret=$1
  shift
  printf '%s' "$secret" | ${SSH_PREFIX[@]+"${SSH_PREFIX[@]}"} ssh "${SSH_OPTS[@]}" "$REMOTE" "MYSQL_PWD=\"\$(cat)\" $*"
}

# rsh_string — the ssh command for rsync's -e, with rsync's own quoting rules.
rsh_string() {
  local out="" a
  for a in ${SSH_PREFIX[@]+"${SSH_PREFIX[@]}"} ssh "${SSH_OPTS[@]}"; do
    case $a in
      *[[:space:]]*) out+=" '$a'" ;;
      *) out+=" $a" ;;
    esac
  done
  printf '%s' "${out# }"
}

open_tunnel() {
  [[ $TUNNEL_OPEN == true ]] && return 0
  TUNNEL_PORT=$(find_free_port 33060) || { error "No free local port found for the SSH tunnel"; return 1; }
  TUNNEL_SOCK="$TMP_DIR/tunnel.sock"
  info "Opening SSH tunnel 127.0.0.1:${TUNNEL_PORT} -> ${export_db_host}:${export_db_port} via ${REMOTE}"
  if ! ${SSH_PREFIX[@]+"${SSH_PREFIX[@]}"} ssh "${SSH_OPTS[@]}" -f -N -M -S "$TUNNEL_SOCK" \
        -o ExitOnForwardFailure=yes \
        -L "127.0.0.1:${TUNNEL_PORT}:${export_db_host}:${export_db_port}" "$REMOTE" \
        >"$TMP_DIR/tunnel.log" 2>&1; then
    error "Could not open the SSH tunnel:"
    sed 's/^/    /' "$TMP_DIR/tunnel.log" >&2
    return 1
  fi
  if ! wait_for_port 127.0.0.1 "$TUNNEL_PORT" 30; then
    error "SSH tunnel port ${TUNNEL_PORT} never came up"
    close_tunnel
    return 1
  fi
  TUNNEL_OPEN=true
}

close_tunnel() {
  [[ ${TUNNEL_OPEN:-false} == true ]] || return 0
  ssh -S "$TUNNEL_SOCK" -O exit "$REMOTE" >/dev/null 2>&1 || true
  TUNNEL_OPEN=false
}
