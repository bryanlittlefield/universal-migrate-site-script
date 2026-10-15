# universal-migrate-site-script

Pull a **WordPress** or **Laravel** site, files and database, from a remote server down to the machine the script runs on, then make it work on a local domain.

**Visual guide with flowcharts and a setup walkthrough:** https://bryanlittlefield.github.io/universal-migrate-site-script/

It is a ground-up rewrite of [builtmighty/migrate-site-script](https://github.com/builtmighty/migrate-site-script) with the same `.env` variable names and step order, so an existing `.env` keeps working. See [CHANGELOG.md](CHANGELOG.md) for what was fixed and added.

```
./migrate.sh --check        # verify SSH, DB access, tools and disk space
./migrate.sh                # interactive: confirm each step
./migrate.sh --yes --plain  # unattended, CI-friendly output
```

## Requirements

| Where | Needed | Notes |
|---|---|---|
| Local | bash 3.2+, `ssh`, `rsync` 3.1+, `mysql`, `gzip` | macOS and Linux both work; Linux is the primary target |
| Local | `mysqldump` | for `db_export_method=tunnel` and the local backup |
| Local | `wp` (WP-CLI) or `php` | for WordPress / Laravel steps |
| Local | `sshpass` | only when authenticating with `remote_ssh_pass` |
| Local | `pv`, `curl`, `unzip` | optional: progress bars, HTTP check, Kinsta plugins |
| Remote | SSH access, `rsync`, `mysqldump` | `mysqldump` only for `db_export_method=remote` |

`./migrate.sh --check` tells you exactly what is missing.

## Quick start

```bash
git clone https://github.com/bryanlittlefield/universal-migrate-site-script.git
cd universal-migrate-site-script
cp .env.example .env
$EDITOR .env            # remote server, remote DB, local web root, local DB, domains
./migrate.sh --check    # preflight only
./migrate.sh            # run it
```

Every run writes `logs/migrate-<timestamp>.log` (everything), `logs/rsync-<timestamp>.log` (every transferred file) and `logs/migrate-report-<timestamp>.txt` (one line per step with real pass/fail and timings).

## Documentation site

[`docs/index.html`](docs/index.html) is a single-page visual guide: flowcharts of a run and of the per-step logic, the two database export methods, a five-step setup walkthrough, the CLI cheat sheet and troubleshooting. A **Technical details** switch in its top bar reveals the exact commands, functions and files behind each section; add `#tech` to the URL to open it that way.

It is plain HTML with no build step and is served by GitHub Pages from the `docs/` folder. To enable it on a fork: repository Settings → Pages → Deploy from a branch → `main` / `/docs`, or

```bash
gh api -X POST repos/<owner>/<repo>/pages -f 'source[branch]=main' -f 'source[path]=/docs'
```

Live copy: https://bryanlittlefield.github.io/universal-migrate-site-script/

## How a run works

1. **Load and validate `.env`**, detect the platform (`wp-config.php` → WordPress, `artisan` → Laravel) if `platform=auto`.
2. **Banner** shows the resolved configuration and which steps will run or be skipped and why.
3. **Preflight**: required tools, SSH login, remote web root, remote DB login, local DB login. Nothing destructive happens if a check fails.
4. **Steps** run in order. Interactively each one asks `Run step '…'? [Y/n]`. With `--yes` they run without asking. A failing step stops the run unless `continue_on_error=true`.
5. **Report** is printed and saved. The exit code is non-zero if any step failed.

| Step id | Default | Platform | What it does |
|---|---|---|---|
| `clear-web-root` | **opt-in** | all | Deletes everything inside `local_web_root` (dotfiles included). Refuses `/`, top-level dirs, `$HOME` and the script's own directory. Interactive runs must type the directory name. |
| `maintenance-on` | run | WP, Laravel | Writes a non-expiring `.maintenance` file / `artisan down`. Skipped automatically if the web root was cleared. |
| `sync-files` | run | all | `rsync` from the remote web root, honouring `config/rsync-exclude.txt`, `sync_mode` and `rsync_mode`. rsync exit 23/24 (vanished or unreadable files) is a warning, not a failure. |
| `migrate-db` | run | all | Lists remote tables, exports (two passes when tables are data-excluded: structure of everything + data of the rest), **backs up the local DB**, drops all local tables and views, imports with session-level bulk settings. Shows table counts. |
| `app-config` | run | WP, Laravel | WordPress: writes `DB_*`, `WP_HOME`, `WP_SITEURL`, runs `wp search-replace` for `www.` variant → domain → extra pairs → scheme (if `remote_scheme` ≠ `local_scheme`), handles multisite (`--network`, `DOMAIN_CURRENT_SITE`). Laravel: updates `APP_URL`, `APP_ENV`, `APP_DEBUG`, `DB_*` in `.env`, generates `APP_KEY` if empty. |
| `host-cleanup` | run | WP | If `wp-config.php` contains WP Engine markers: backs it up and removes the lines matched by `config/wpe-config-patterns.txt`. Removes the mu-plugins in `config/host-mu-plugins.txt` and the `object-cache.php` / `advanced-cache.php` drop-ins. |
| `kinsta-plugins` | **opt-in** | WP | Downloads and unzips Kinsta's MU plugins. Only when the destination is Kinsta. |
| `local-hardening` | run | WP | `WP_ENVIRONMENT_TYPE`, `WP_DEBUG`, `blog_public=0`, deactivates plugins in `config/host-plugins-deactivate.txt`, optionally creates or updates a local admin user. |
| `cache-refresh` | run | WP, Laravel | `wp rewrite flush`, `wp cache flush`, `wp transient delete --all` (+ Kinsta purge if available) / `artisan optimize:clear`. |
| `verify` | run | all | Site loads (`wp core version` / `artisan --version`), `home` option contains the local domain, remote vs local table count, HTTP status of the local domain. Only hard failures fail the step. |
| `maintenance-off` | run | WP, Laravel | Removes `.maintenance` / `artisan up`. If the run aborts with maintenance still on, the script says so on exit. |

`./migrate.sh --list-steps` prints this list.

## Command line

```
-e, --env FILE      Env file to load (default: ./.env)
-y, --yes           Unattended: run every enabled step without prompting
-n, --dry-run       Show what would happen; change no files, DB or config
-c, --check         Run the preflight checks (incl. disk space) and exit
    --skip IDS      Comma-separated step ids to skip (repeatable)
    --only IDS      Run only these step ids (repeatable)
    --with IDS      Enable opt-in steps, e.g. clear-web-root, kinsta-plugins
    --plain         No colours or emoji (CI-friendly output)
    --list-steps    Print the step ids and exit
-V, --version
-h, --help
```

Examples:

```bash
./migrate.sh --only migrate-db                       # just refresh the database
./migrate.sh --yes --skip sync-files                 # unattended, DB and config only
./migrate.sh --yes --with clear-web-root             # full wipe + sync, unattended
./migrate.sh --env sites/client-a.env --dry-run      # several sites, one checkout
```

### Opt-in steps and unattended runs

`clear-web-root` and `kinsta-plugins` never run under `--yes` unless you name them: `--with <id>`, `--only <id>`, or `run_<id>=true` in `.env` (e.g. `run_clear_web_root='true'`). Interactively they simply default to **No** at the prompt.

Without a terminal and without `--yes` (cron, CI without `-t`), the script refuses to start instead of guessing.

### Exit codes

| Code | Meaning |
|---|---|
| `0` | Every step that ran succeeded. Skipped steps do not affect the code. |
| `1` | A step failed, the preflight failed, or the `.env` is invalid or missing. |
| `2` | Unknown command-line option. |
| `130` | Interrupted with Ctrl-C. The cleanup trap still closes the tunnel and removes temp files. |

## Configuration

All settings live in `.env`; see [.env.example](.env.example) for every key with comments. The important ones:

### Remote server and database

| Key | Default | Meaning |
|---|---|---|
| `remote_ssh_host`, `remote_ssh_user`, `remote_ssh_port` | `22` | SSH endpoint |
| `remote_ssh_key` | | Private key path (recommended). Empty = ssh-agent / interactive |
| `remote_ssh_pass` | | Password auth via `sshpass` (delivered through the environment, not the command line) |
| `remote_ssh_web_root` | | Absolute path of the site on the remote |
| `remote_domain`, `remote_scheme` | `https` | Public domain of the remote site |
| `ssh_strict_host_key` | `accept-new` | `yes`, `no` or `accept-new` (OpenSSH ≥ 7.6). The original script used `no`. |
| `export_db_name`, `export_db_user`, `export_db_pass` | | Remote DB credentials |
| `export_db_host`, `export_db_port` | `127.0.0.1`, `3306` | DB host **as seen from the remote server** |
| `db_export_method` | `tunnel` | `tunnel` or `remote`, see below |
| `db_transfer_compress` | `auto` | gzip the stream for the remote method |
| `export_db_ssl_flag`, `import_db_ssl_flag` | auto | Override the detected client SSL flag if needed |
| `mysqldump_extra_opts` | | e.g. `--routines --events` |

### Local server and database

| Key | Default | Meaning |
|---|---|---|
| `local_web_root` | | Absolute path to sync into |
| `local_domain`, `local_scheme` | `https` | Local domain. If the scheme differs from `remote_scheme`, URLs are rewritten accordingly |
| `import_db_*` | `127.0.0.1:3306` | Local DB credentials |
| `create_local_db` | `true` | Create the database if missing |
| `local_db_backup` | `true` | Back up the existing local DB before dropping tables (`dumps/<db>-backup-<ts>.sql.gz`) |
| `db_fix_collation` | `auto` | Map `utf8mb4_0900_*` (MySQL 8) collations when the local server is MariaDB or MySQL < 8 |
| `keep_dump` | `true` | Keep the downloaded dump in `dumps/` |

### Files

| Key | Default | Meaning |
|---|---|---|
| `sync_mode` | `full` | `full`, `code` (skip uploads), `uploads` (only uploads) |
| `rsync_mode` | `sync` | `sync` (transfer changed files), `ignore-existing` (only new files, the original behaviour), `mirror` (`--delete` local extras) |
| `rsync_bwlimit`, `rsync_extra_opts` | | Throttle or extend rsync |
| `rsync_exclude_file_path` | `config/rsync-exclude.txt` | rsync filter rules. Patterns starting with `/` are anchored at the web root |
| `uploads_rel_path` | by platform | `wp-content/uploads` or `storage/app/public` |

### WordPress

| Key | Default | Meaning |
|---|---|---|
| `replace_www_variant` | `true` | Also replace `www.<remote_domain>` |
| `domain_pairs_file_path` | `config/domain-pairs.txt` | Extra `old new` pairs for search-replace (multisite subdomains, CDN hosts) |
| `wp_search_replace_exclude_file_path` | `config/wp-search-replace-exclude.txt` | Tables skipped by search-replace |
| `db_exclude_tables_file_path` | `config/db-tables-exclude.txt` | Tables exported **without data** (wildcards allowed) |
| `wp_environment_type`, `wp_debug`, `wp_discourage_search_engines`, `wp_remove_dropins` | `local`, `true`, `true`, `true` | Local hardening |
| `wp_local_admin_user`, `wp_local_admin_pass`, `wp_local_admin_email` | | Create/update a local administrator |
| `wp_cli_extra_opts` | | e.g. `--skip-plugins --skip-themes` if a plugin fatals under WP-CLI |
| `host_mu_plugins_file_path`, `host_plugins_deactivate_file_path`, `wpe_config_patterns_file_path` | `config/…` | What host-cleanup / local-hardening remove or deactivate |

### Behaviour and steps

| Key | Default | Meaning |
|---|---|---|
| `auto_confirm`, `plain_output` | `false` | Same as `--yes`, `--plain` |
| `continue_on_error` | `false` | Keep running later steps after a failure |
| `log_dir`, `dump_dir` | `logs`, `dumps` | Relative to the script directory |
| `preflight_disk_check` | `false` | Compare remote size (`du`) with local free space before syncing; slow on large sites. Always on with `--check` |
| `verify_http`, `verify_db_check` | `true`, `false` | Extra checks in the verify step |
| `skip_migrate_website` | `false` | Exit immediately; handy for wrapper scripts |
| `skip_clear_web_root`, `skip_maintenance`, `skip_file_sync`, `skip_db_import`, `skip_app_config`, `skip_host_cleanup`, `skip_kinsta_plugins`, `skip_local_hardening`, `skip_cache_refresh`, `skip_verify` | `false` | Skip a step |
| `run_clear_web_root`, `run_kinsta_plugins` | `false` | Enable an opt-in step |

## Database export methods

**`tunnel`** (default): the script opens `ssh -L` from a free local port to `export_db_host:export_db_port` *as seen from the remote server* and runs the **local** `mysqldump` through it. Use this when the remote has no `mysqldump`, or when the DB lives on a separate host the web server can reach (set `export_db_host` to that host).

**`remote`**: the script runs `mysqldump` **on the remote server** and streams the output back over the same SSH connection, gzip-compressed when both ends have gzip. No temp files are written on the remote. Usually the fastest option for large databases.

In both cases the dump is filtered on the fly: `DEFINER` clauses are stripped, the MariaDB "sandbox mode" line is removed, and collations are mapped when `db_fix_collation` applies. The remote password is passed through `stdin`/`MYSQL_PWD`, the local one through a temporary `--defaults-extra-file`; neither appears in `ps`.

The right SSL flag for each client (`--skip-ssl` for MariaDB and MySQL 5.x clients, `--ssl-mode=…` for MySQL 8) is detected from `mysql --version`; set `export_db_ssl_flag` / `import_db_ssl_flag` to override.

## The list files in `config/`

| File | Used by | Format |
|---|---|---|
| `rsync-exclude.txt` | sync-files | rsync filter rules; `/wp-content/cache/` anchors at the web root |
| `db-tables-exclude.txt` | migrate-db | Tables to export without data; `*` and `?` wildcards expand against the remote table list. Unknown literal names produce a warning |
| `wp-search-replace-exclude.txt` | app-config | Tables skipped by `wp search-replace` (passed to `--skip-tables`) |
| `domain-pairs.txt` | app-config | `old new` per line, run after the main domain replacement |
| `host-mu-plugins.txt` | host-cleanup | mu-plugin files/dirs to delete |
| `host-plugins-deactivate.txt` | local-hardening | Plugin slugs to deactivate if installed |
| `wpe-config-patterns.txt` | host-cleanup | Regexes; matching `wp-config.php` lines are deleted when WP Engine markers are present |

Blank lines and `#` comments are ignored in all of them.

## Safety

- The only step that deletes files wholesale is `clear-web-root`, and it is opt-in with multiple guards.
- The local database is backed up before its tables are dropped (`local_db_backup=true`).
- `wp-config.php` is backed up before host-cleanup edits it.
- `--dry-run` runs the read-only parts (SSH, table listing, rsync `--dry-run`) and prints every command it would run, with secrets masked.
- A cleanup trap closes the SSH tunnel and removes temp files on exit, and warns if maintenance mode is still active.
- Remote commands run with `ssh -n`, so a remote call can never consume the script's own stdin (for example inside a `while read` loop). Only the password-delivering call forwards stdin.
- The SSH tunnel is a control-socket master (`ssh -M -S`) and is torn down with `ssh -O exit`, so no stray tunnel outlives a run, even an interrupted one.
- `.env` is git-ignored. Never commit it: the original repository's history contains real credentials for exactly this reason.

## Troubleshooting

**`SSL connection error` / `TLS/SSL error: self-signed certificate`** – a MariaDB 11.4+ client talking to a server without certificates. The script already passes `--skip-ssl` on loopback connections; for other hosts set `export_db_ssl_flag='--skip-ssl'` (MariaDB client) or `--ssl-mode=DISABLED` (MySQL client).

**`Unknown collation: 'utf8mb4_0900_ai_ci'`** – a MySQL 8 dump imported into MariaDB or MySQL 5.7. `db_fix_collation=auto` handles it when the local server is detected as such; force it with `db_fix_collation='true'`.

**`Unknown table 'COLUMN_STATISTICS'`** – MySQL 8 `mysqldump` against an older server. The script adds `--column-statistics=0` automatically for MySQL 8/9 clients.

**`rsync: … --info=progress2 unknown option`** – rsync < 3.1 (e.g. macOS's bundled version). The progress bar is skipped automatically; install a newer rsync for progress output.

**`Bad configuration option: StrictHostKeyChecking=accept-new`** – OpenSSH < 7.6. Set `ssh_strict_host_key='yes'` (and accept the key once manually) or `'no'`.

**The tunnel never comes up** – check `remote_ssh_key` permissions (`chmod 600`), and that the remote host allows TCP forwarding (`AllowTcpForwarding yes`). Switch to `db_export_method=remote` as a workaround.

**Plugin fatal errors during `wp search-replace`** – set `wp_cli_extra_opts='--skip-plugins --skip-themes'`.

## Upgrading from migrate-site-script

Copy your old `.env` over; it works as is. Mapping of behaviours:

| Old | New |
|---|---|
| `bash migrate-website.sh` | `./migrate.sh` |
| Prompts phrased as "Skip X? (y/n)" | Every prompt is "Run step 'X'? [Y/n]"; `y` always means run |
| `db_ssh_tunnels='true'` / `'false'` | still works; maps to `db_export_method=tunnel` / `remote` |
| `rsync-exclude.txt`, `db-tables-exclude.txt`, `wp-search-replace-exclude.txt` in the repo root | moved to `config/`; old paths in `.env` fall back to `config/` automatically |
| `no_tables_ignored` sentinel in the exclude file | an empty file (the sentinel is still accepted) |
| rsync always `--ignore-existing` | `rsync_mode=sync` by default; set `rsync_mode='ignore-existing'` for the old behaviour |
| `apt install pv sshpass` on every run | preflight reports what is missing; nothing is installed for you |
| Report said ✅ for every step | report reflects the real exit status |
| `local_db_backup_filename` documented but unused | a backup is actually taken |

## Development

```bash
shellcheck -x migrate.sh                                  # lints every sourced file too
shellcheck -s bash tests/stubs/bin/* tests/test_helper.bash
bats tests                                                # 54 tests: unit + end-to-end against stubbed ssh/rsync/mysql/wp/php
bats tests/e2e.bats                                       # one suite
```

The end-to-end tests run `migrate.sh --yes --plain` against fake binaries in `tests/stubs/bin` that log every call to `$STUB_LOG`; the tunnel test fakes a listener with `python3`. Nothing talks to a real server or database.

Layout:

```
migrate.sh          entry point: CLI parsing, step registry, main()
lib/util.sh         portable helpers (bash 3.2 safe)
lib/ui.sh           colours, icons, prompts
lib/env.sh          .env loading, legacy aliases, defaults, validation, platform detection
lib/ssh.sh          ssh options, remote execution, tunnel
lib/db.sh           mysql client flags, dump filter, local/remote DB helpers
lib/wp.sh           WP-CLI wrappers
lib/runner.sh       step runner, skip logic, report
lib/preflight.sh    checks that run before anything destructive
steps/*.sh          one function per step
config/*.txt        editable lists
tests/              bats suites, stub binaries in tests/stubs/bin, fixtures
docs/               the GitHub Pages guide (index.html, no build step)
.github/workflows/  CI: shellcheck + bats on Ubuntu and macOS
```

Adding a step: write `step_<name>()` in `steps/<name>.sh`, source it in `migrate.sh`, add a `register_step` line. The runner handles prompting, skipping, timing and reporting. Use `run_cmd` for anything that changes state so `--dry-run` works, and `return 1` on failure.

Portability rules the code follows, because macOS still ships bash 3.2:

- No bash 4 features (`mapfile`, `declare -A`, `${var,,}`). `set -u` is on, so expand possibly-empty arrays as `${arr[@]+"${arr[@]}"}`.
- No `case` patterns with two quoted segments (`*"a "*" b"*`); bash 3.2 never matches them. Use one quoted segment.
- No GNU-only tools: use `sed_inplace` instead of `sed -i`, and no `timeout`, `readlink -f` or `stat -c`.

CI runs shellcheck and the test suite on Ubuntu and macOS (bash 3.2) on every push.
