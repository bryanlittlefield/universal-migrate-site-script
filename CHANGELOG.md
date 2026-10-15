# Changelog

## 1.0.0 — 2026-10-14

First release. A ground-up rewrite of [builtmighty/migrate-site-script](https://github.com/builtmighty/migrate-site-script)
that keeps its `.env` variable names and step order.

### Fixed (compared with the original)
- The WP Engine cleanup step never ran (missing `&&`), and when fixed it deleted the `WP_HOME`/`WP_SITEURL` lines the previous step had just written.
- Table exclusion built `--ignore-table=.table` because `DB_NAME` was never set.
- The Laravel config step edited `/.env` because `DOCUMENT_ROOT` was never set.
- Most rsync exclude patterns (`./wp-content/cache/` etc.) never matched; cache and backup directories were synced.
- An empty `local_web_root` made the "clear web root" step run `rm -rf *` in the current directory.
- A stale local dump was re-imported because the dump copy used `--ignore-existing`.
- Missing `skip_*` variables silently skipped steps instead of defaulting to false.
- Passwords with spaces, quotes or `#` broke the `.env` loader.
- `#!/bin/sh` shebang with bash-only syntax (works on macOS, breaks on Debian's dash).
- Every step reported ✅ regardless of its exit status.
- `SET GLOBAL` statements prepended to the dump required SUPER and failed for normal users.
- SSH tunnel: fixed port, infinite wait on auth failure, `kill -9` of whatever `lsof` found.

### Added
- Preflight checks (`--check`): binaries, SSH, remote web root, remote and local DB auth, optional disk space.
- Unattended mode (`--yes`), `--dry-run`, `--skip/--only/--with`, `--plain`, `--list-steps`.
- Local database backup before the existing tables are dropped.
- Streaming, gzip-compressed export for the remote method (no temp files on the remote).
- MySQL 8 → MariaDB / MySQL 5.7 collation mapping (`db_fix_collation`).
- Client SSL flag detection for MariaDB vs MySQL clients (replaces the `--skip-ssl` / `--ssl-mode` back-and-forth).
- `sync_mode` (full / code / uploads) and `rsync_mode` (sync / ignore-existing / mirror).
- Multi-domain search-replace (`config/domain-pairs.txt`), `www.` variant and scheme (https → http) handling.
- Local WordPress hardening: `WP_ENVIRONMENT_TYPE`, `WP_DEBUG`, noindex, host plugin deactivation, optional admin user.
- Verify step: site loads, URLs, table counts, HTTP check.
- Full run log, step-by-step report with real pass/fail, cleanup trap (tunnel, temp files, maintenance warning).
- Secrets kept off command lines (`--defaults-extra-file`, `MYSQL_PWD` via stdin, `sshpass -e`).
- bats test suite with stubbed binaries, shellcheck, GitHub Actions on Ubuntu and macOS.
