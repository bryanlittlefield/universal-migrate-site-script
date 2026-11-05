#!/usr/bin/env bash
# gui.sh — start the local web GUI for migrate.sh (see "GUI" in README.md).
#   ./gui.sh [--port N] [--no-browser]
set -euo pipefail
dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
if ! command -v python3 >/dev/null 2>&1; then
  printf 'The GUI needs python3 (3.8 or newer). The command line works without it: ./migrate.sh --help\n' >&2
  exit 1
fi
exec python3 "$dir/gui/server.py" "$@"
