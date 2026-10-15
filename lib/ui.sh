#!/usr/bin/env bash
# lib/ui.sh — colours, icons, output helpers and prompts.

# shellcheck disable=SC2034  # colour variables are used by other files
ui_init() {
  STDOUT_IS_TTY=false
  [[ -t 1 ]] && STDOUT_IS_TTY=true
  local want_color=true
  if is_true "${plain_output:-false}" || [[ -n ${NO_COLOR:-} ]] || [[ $STDOUT_IS_TTY != true ]] \
     || [[ -z ${TERM:-} || ${TERM:-} == dumb ]] || ! have_cmd tput; then
    want_color=false
  fi
  if [[ $want_color == true ]]; then
    C_RED=$(tput setaf 1) C_GREEN=$(tput setaf 2) C_YELLOW=$(tput setaf 3) C_BLUE=$(tput setaf 4)
    C_MAGENTA=$(tput setaf 5) C_CYAN=$(tput setaf 6) C_BOLD=$(tput bold) C_RESET=$(tput sgr0)
    C_GREY=$(tput setaf 8 2>/dev/null || tput dim 2>/dev/null || true)
  else
    C_RED="" C_GREEN="" C_YELLOW="" C_BLUE="" C_MAGENTA="" C_CYAN="" C_GREY="" C_BOLD="" C_RESET=""
  fi
  if is_true "${plain_output:-false}"; then
    I_OK="[OK]" I_FAIL="[FAIL]" I_SKIP="[SKIP]" I_WARN="[WARN]" I_INFO="[INFO]" I_Q="[?]"
  else
    I_OK="✅" I_FAIL="❌" I_SKIP="⏭️ " I_WARN="⚠️ " I_INFO="ℹ️ " I_Q="❓"
  fi
}

ts() { date +'%Y-%m-%d %H:%M:%S'; }
say() { printf '%s\n' "$*"; }
info() { printf '%s %s\n' "${I_INFO-}" "$*"; }
ok() { printf '%s%s %s%s\n' "${C_GREEN-}" "${I_OK-}" "$*" "${C_RESET-}"; }
warn() { printf '%s%s %s%s\n' "${C_YELLOW-}" "${I_WARN-}" "$*" "${C_RESET-}" >&2; }
error() { printf '%s%s %s%s\n' "${C_RED-}" "${I_FAIL-}" "$*" "${C_RESET-}" >&2; }
die() { error "$@"; exit 1; }
hr() { printf '%s\n' "------------------------------------------------------------------"; }
section() {
  printf '\n%s%s[%s] %s%s\n' "${C_BOLD-}" "${C_CYAN-}" "$(ts)" "$*" "${C_RESET-}"
  hr
}

# confirm QUESTION [DEFAULT y|n] [AUTO_ANSWER y|n]
#   Interactive: asks, Enter picks DEFAULT.
#   --yes / auto_confirm: answers AUTO_ANSWER without asking.
#   No TTY and no --yes: answers "no" (and says why) so nothing runs by accident.
confirm() {
  local question=$1 default=${2:-n} auto=${3:-y} hint answer
  if is_true "${AUTO_CONFIRM:-false}"; then
    [[ $auto == y ]]
    return $?
  fi
  if [[ ! -t 0 ]]; then
    warn "No terminal to answer '${question}'. Assuming no (use --yes for unattended runs)."
    return 1
  fi
  if [[ $default == y ]]; then hint="[Y/n]"; else hint="[y/N]"; fi
  while true; do
    printf '%s %s %s ' "${I_Q-}" "$question" "$hint"
    read -r answer || answer=""
    answer=$(to_lower "$(trim "${answer:-$default}")")
    case $answer in
      y|yes) return 0 ;;
      n|no) return 1 ;;
      *) say "Please answer y or n." ;;
    esac
  done
}
