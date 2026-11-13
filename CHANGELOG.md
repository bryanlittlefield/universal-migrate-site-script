# Changelog

## Unreleased

### Added
- Non-standard WordPress layouts (hosts that manage core themselves): `sync_path` syncs one folder inside the web root (e.g. `wp-content`) instead of the whole install, `wp_cli_path` sets the folder every WP-CLI command runs against, and `wp_config_path` points at a `wp-config.php` outside the web root. In the GUI they are under Setup → Remote server → Advanced.
- `use_pv` (default `true`, also in the GUI under Behaviour): set `false` to turn off the `pv` progress bars for the database export and import without losing colours. Each bar is an extra process, which matters on hosts that cap processes per account.

### Changed
- Docs site (GitHub Pages): now three pages. `docs/index.html` is a landing page with an overview and two large buttons to pick a guide; the command-line guide moved to `docs/cli.html` (old `#section` links to the site root, such as `/#setup` or `/#tech`, are redirected there); `docs/gui.html` is a new GUI guide with a screenshot tour. Shared styles and script live in `docs/assets/`, screenshots in `docs/img/`.
- Docs: the CLI guide now covers the `before-run` / `after-run` hook steps (13 steps, not 11), `--test`, the `.events` file and the GUI tests, and its test count is current.
- Docs: the README (contents list, a *Non-standard WordPress layouts* section, new troubleshooting entries), the Pages guide and the GUI's built-in guide now describe the download-then-filter export, `use_pv`, `sync_path`, `wp_cli_path` and `wp_config_path`.
- The database export downloads the raw dump to `<dump>.raw[.gz]` first and filters it (DEFINERs, collations) in a second pass instead of streaming through `gunzip | sed | pv`. Only `ssh` (or the local `mysqldump` for the tunnel method) runs during the transfer, which keeps the run under per-account process limits on managed hosts (`Process count of N exceeded maximum allowed value of 25`).

### Fixed
- WP-CLI calls put `--quiet` before the command. Hosts that set `WP_CLI_STRICT_ARGS_MODE` rejected it after the command with `unknown --quiet parameter`, failing `app-config`.
- `sync-files` passes `--omit-dir-times`, so a local web root the account can write to but doesn't own no longer fails with `failed to set times on "…/.": Operation not permitted` (rsync exit 23). File modification times are still preserved.

## 1.2.0 — 2026-10-20

### Added
- **GUI** (`./gui.sh`): a local, dependency-free web interface (Python 3.8+ standard library, vanilla JS). It includes a setup wizard with tooltips and visual helpers, connection tests before a run, several migrations (`.env` plus `sites/<name>.env`), step toggles, before/after hook editing, runs with live per-step progress and Stop, run history and a log browser. It has a built-in user guide and binds to 127.0.0.1 with a per-launch token.
- `before_run_hook` / `after_run_hook` and the `before-run` / `after-run` steps: your own script or command first and last, with `UMS_*` variables.
- `--test IDS` (`tools`, `local-root`, `ssh`, `remote-db`, `local-db`, `disk`): run individual preflight checks without a log, even before the local side is configured.
- `logs/migrate-<tag>.events`: machine-readable progress for each run (plan, checks, step start/end/skip, exit code).
- `MIGRATE_RUN_TAG` environment variable to choose the run's file names (used by the GUI).

### Changed
- Preflight decides which checks apply in `preflight_run`, so each `pf_check_*` can also run on its own.

## 1.1.0 — 2026-10-15

### Added
- `db_preserve_tables`: local tables (wildcards allowed) whose data survives the import. They are saved before the local tables are dropped, only their structure is taken from the remote, and they are restored after the import. Typical use: `db_preserve_tables='wp_options'` with `sync_mode='uploads'` to refresh media and content while keeping local URLs and settings.
- README "Common recipes" section; the GitHub Pages guide and the SQL test fixture are now tracked.

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
