#!/usr/bin/env bash
# shellcheck disable=SC2034  # STUB_BIN and FIXTURES are used by the .bats files
# Shared helpers for the bats suites.
REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
STUB_BIN="$REPO_ROOT/tests/stubs/bin"
FIXTURES="$REPO_ROOT/tests/fixtures"

# Source the libraries into the test shell (no migrate.sh main()).
load_libs() {
  set +u
  # shellcheck disable=SC1091
  source "$REPO_ROOT/lib/util.sh"
  # shellcheck disable=SC1091
  source "$REPO_ROOT/lib/ui.sh"
  # shellcheck disable=SC1091
  source "$REPO_ROOT/lib/env.sh"
  # shellcheck disable=SC1091
  source "$REPO_ROOT/lib/ssh.sh"
  # shellcheck disable=SC1091
  source "$REPO_ROOT/lib/db.sh"
  # shellcheck disable=SC1091
  source "$REPO_ROOT/lib/runner.sh"
  plain_output=true
  ui_init
}

new_tmp() { mktemp -d "${TMPDIR:-/tmp}/ums-test.XXXXXX"; }
