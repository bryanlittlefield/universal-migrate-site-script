#!/usr/bin/env python3
"""Local web GUI for universal-migrate-site-script.

Standard library only (Python 3.8+), no build step. It serves the page in
gui/static and a small JSON API that reads and writes env files, runs
migrate.sh --test / --check / full runs, and reads the run history from the
.events, .log and report files migrate.sh writes into log_dir.

    ./gui.sh                 # http://127.0.0.1:8765, opens the browser
    ./gui.sh --port 9000 --no-browser

Binds to 127.0.0.1 only. Every API call must carry the per-launch token that
is printed in the URL, so other web pages cannot drive it.
"""

import argparse
import errno
import json
import os
import re
import secrets
import signal
import subprocess
import sys
import tempfile
import threading
import time
import webbrowser
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

ROOT = Path(__file__).resolve().parent.parent
MIGRATE = ROOT / "migrate.sh"
EXAMPLE = ROOT / ".env.example"
DEFAULT_ENV = ROOT / ".env"
SITES_DIR = ROOT / "sites"
HOOKS_DIR = ROOT / "hooks"
STATIC_DIR = Path(__file__).resolve().parent / "static"
SCHEMA_FILE = Path(__file__).resolve().parent / "schema.json"

STATIC_FILES = {
    "/": ("index.html", "text/html; charset=utf-8"),
    "/index.html": ("index.html", "text/html; charset=utf-8"),
    "/app.css": ("app.css", "text/css; charset=utf-8"),
    "/app.js": ("app.js", "text/javascript; charset=utf-8"),
}
TEST_IDS = ["tools", "local-root", "ssh", "remote-db", "local-db", "disk"]
HOOK_NAMES = {"before": "before_run_hook", "after": "after_run_hook"}
PROFILE_RE = re.compile(r"^[a-z0-9][a-z0-9_-]{0,47}$")
TAG_RE = re.compile(r"^[A-Za-z0-9_.-]+$")
KEY_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")
POLL_LIMIT = 512 * 1024

# Never let a child ssh pop up a password dialog or wait on a terminal.
CHILD_ENV = dict(os.environ, SSH_ASKPASS_REQUIRE="never")
CHILD_ENV.pop("SSH_ASKPASS", None)


class ApiError(Exception):
    def __init__(self, status, message):
        super().__init__(message)
        self.status = status
        self.message = message


# ------------------------------------------------------------------ env files

def shell_quote(value):
    """Single-quote VALUE the way .env.example recommends."""
    return "'" + str(value).replace("'", "'\\''") + "'"


def _scan_word(text, i):
    """End index of the shell word that starts at I (quotes and escapes aware)."""
    n = len(text)
    while i < n:
        c = text[i]
        if c == "'":
            j = text.find("'", i + 1)
            i = n if j < 0 else j + 1
        elif c == '"':
            i += 1
            while i < n and text[i] != '"':
                i += 2 if text[i] == "\\" else 1
            i += 1
        elif c == "\\":
            i += 2
        elif c in " \t\n;":
            break
        else:
            i += 1
    return min(i, n)


def set_env_values(text, updates):
    """Return TEXT with every KEY=... assignment in UPDATES replaced (all
    occurrences, inline comments kept in their column) or appended."""
    appended = []
    for key, value in updates.items():
        if not KEY_RE.match(key):
            raise ApiError(400, "Invalid key: %s" % key)
        new = shell_quote(value)
        pattern = re.compile(r"^[ \t]*(?:export[ \t]+)?" + re.escape(key) + "=", re.M)
        matches = list(pattern.finditer(text))
        if not matches:
            appended.append("%s=%s" % (key, new))
            continue
        for m in reversed(matches):
            start = m.end()
            end = _scan_word(text, start)
            ws_end = end
            while ws_end < len(text) and text[ws_end] in " \t":
                ws_end += 1
            if ws_end < len(text) and text[ws_end] == "#" and ws_end > end:
                pad = max(1, (ws_end - start) - len(new))
                text = text[:start] + new + " " * pad + text[ws_end:]
            else:
                text = text[:start] + new + text[end:]
    if appended:
        if text and not text.endswith("\n"):
            text += "\n"
        text += "\n# ---------------------------------------------------------------- Added by the GUI\n"
        text += "\n".join(appended) + "\n"
    return text


def keys_in_text(text):
    return re.findall(r"^[ \t]*(?:export[ \t]+)?([A-Za-z_][A-Za-z0-9_]*)=", text, re.M)


def source_env(path, keys):
    """Values of KEYS after bash sources PATH (the way migrate.sh loads it)."""
    script = (
        'set -a; . "$1" >/dev/null 2>&1; rc=$?; set +a; shift; '
        'for k in "$@"; do printf "%s\\0%s\\0" "$k" "${!k-}"; done; exit $rc'
    )
    proc = subprocess.run(
        ["bash", "-c", script, "ums-gui", str(path)] + list(keys),
        stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        cwd=str(ROOT), env=CHILD_ENV, timeout=20,
    )
    parts = proc.stdout.decode("utf-8", "replace").split("\0")
    values = {}
    for i in range(0, len(parts) - 1, 2):
        values[parts[i]] = parts[i + 1]
    return values, proc.returncode


def parse_example():
    """Keys of .env.example in file order, with defaults, comments and the
    section each one sits under."""
    text = EXAMPLE.read_text(encoding="utf-8")
    keys, comments, sections = [], {}, {}
    section, last = "", None
    for line in text.splitlines():
        m = re.match(r"^# -+ (.+)$", line)
        if m:
            section, last = m.group(1).strip(), None
            continue
        m = re.match(r"^([A-Za-z_][A-Za-z0-9_]*)=", line)
        if m:
            key = m.group(1)
            rest = line[_scan_word(line, m.end()):]
            c = re.match(r"\s*#\s?(.*)$", rest)
            keys.append(key)
            comments[key] = c.group(1).strip() if c else ""
            sections[key] = section
            last = key
            continue
        m = re.match(r"^\s{10,}#\s?(.*)$", line)
        if m and last:
            comments[last] = (comments[last] + " " + m.group(1).strip()).strip()
        else:
            last = None
    defaults, _ = source_env(EXAMPLE, keys)
    return {"keys": keys, "defaults": defaults, "comments": comments, "sections": sections}


# ------------------------------------------------------------------ profiles

def profile_path(pid):
    if pid == "default":
        return DEFAULT_ENV
    if not PROFILE_RE.match(pid or ""):
        raise ApiError(400, "Invalid migration name")
    return SITES_DIR / (pid + ".env")


def profile_ids():
    ids = []
    if DEFAULT_ENV.is_file():
        ids.append("default")
    if SITES_DIR.is_dir():
        for f in sorted(SITES_DIR.glob("*.env")):
            if PROFILE_RE.match(f.stem) and f.stem != "default":
                ids.append(f.stem)
    return ids


def rel(path):
    try:
        return str(Path(path).resolve().relative_to(ROOT))
    except ValueError:
        return str(path)


def cli_for(pid):
    return "./migrate.sh" if pid == "default" else "./migrate.sh --env sites/%s.env" % pid


def write_private(path, text):
    """Write TEXT to PATH with mode 600 (credentials live here)."""
    path.parent.mkdir(parents=True, exist_ok=True)
    fd = os.open(str(path), os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        fh.write(text)
    os.chmod(str(path), 0o600)


def resolve_from_root(value):
    p = Path(os.path.expanduser(value))
    return p if p.is_absolute() else ROOT / p


class Profiles:
    def __init__(self, example):
        self.example = example

    def load(self, pid):
        path = profile_path(pid)
        if not path.is_file():
            raise ApiError(404, "Migration '%s' not found" % pid)
        text = path.read_text(encoding="utf-8")
        present = keys_in_text(text)
        keys = list(self.example["keys"]) + [k for k in present if k not in self.example["keys"]]
        values, rc = source_env(path, keys)
        for k in keys:
            if k not in present:
                values[k] = self.example["defaults"].get(k, "")
        return {"path": path, "text": text, "present": present, "values": values, "source_rc": rc}

    def log_dir(self, values):
        return resolve_from_root(values.get("log_dir") or "logs")

    def hook_info(self, pid, values):
        out = {}
        for name, key in HOOK_NAMES.items():
            value = values.get(key, "")
            target = resolve_from_root(value) if value else None
            if target and target.is_file():
                out[name] = {"key": key, "value": value, "kind": "file", "file": rel(target),
                             "content": target.read_text(encoding="utf-8", errors="replace")}
            elif value:
                out[name] = {"key": key, "value": value, "kind": "command", "file": "", "content": value}
            else:
                out[name] = {"key": key, "value": "", "kind": "none", "file": "", "content": ""}
        return out

    def describe(self, pid):
        data = self.load(pid)
        v = data["values"]
        return {
            "id": pid,
            "file": rel(data["path"]),
            "cli": cli_for(pid),
            "remote": "%s@%s" % (v.get("remote_ssh_user", ""), v.get("remote_ssh_host", "")) if v.get("remote_ssh_host") else "",
            "remote_domain": v.get("remote_domain", ""),
            "local_domain": v.get("local_domain", ""),
            "local_web_root": v.get("local_web_root", ""),
            "platform": v.get("platform", "auto"),
            "last_run": next(iter(list_runs(self.log_dir(v), data["path"], limit=1)), None),
        }

    def save(self, pid, values, hooks):
        data = self.load(pid)
        current = data["values"]
        updates = {}
        for key, value in (values or {}).items():
            if not KEY_RE.match(key):
                raise ApiError(400, "Invalid key: %s" % key)
            value = "" if value is None else str(value)
            if value != current.get(key, "") or (key not in data["present"] and value != ""):
                updates[key] = value
        for name, content in (hooks or {}).items():
            if name not in HOOK_NAMES or content is None:
                continue
            key = HOOK_NAMES[name]
            value = updates.get(key, current.get(key, ""))
            if not content.strip():
                if value:
                    updates[key] = ""
                continue
            target = resolve_from_root(value) if value else None
            if not (target and target.is_file()):
                target = HOOKS_DIR / pid / ("%s-run.sh" % name)
            if not content.endswith("\n"):
                content += "\n"
            write_private(target, content)
            updates[key] = rel(target)
        if updates:
            write_private(data["path"], set_env_values(data["text"], updates))
        return sorted(updates)

    def create(self, pid, copy_from=None):
        path = profile_path(pid)
        if path.exists():
            raise ApiError(409, "A migration called '%s' already exists" % pid)
        if copy_from:
            text = self.load(copy_from)["text"]
        else:
            text = EXAMPLE.read_text(encoding="utf-8")
            text = re.sub(r"\A# universal-migrate-site-script configuration\n",
                          "# universal-migrate-site-script configuration (%s)\n" % pid, text)
        write_private(path, text)

    def delete(self, pid):
        path = profile_path(pid)
        if not path.is_file():
            raise ApiError(404, "Migration '%s' not found" % pid)
        path.unlink()

    def temp_env(self, pid, values):
        """A throwaway env file: the saved profile (or the example) with the
        form's unsaved VALUES applied. Caller deletes it."""
        base = EXAMPLE.read_text(encoding="utf-8")
        if pid and profile_path(pid).is_file():
            base = profile_path(pid).read_text(encoding="utf-8")
        text = set_env_values(base, {k: "" if v is None else str(v) for k, v in (values or {}).items()})
        fd, name = tempfile.mkstemp(prefix="ums-gui-", suffix=".env")
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(text)
        os.chmod(name, 0o600)
        return name


# ------------------------------------------------------------------ runs

def pid_alive(pid):
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    except OSError:
        return False
    cmdline = Path("/proc/%d/cmdline" % pid)
    if cmdline.exists():
        try:
            return b"migrate.sh" in cmdline.read_bytes()
        except OSError:
            return True
    return True


def parse_events(path):
    run = {"tag": "", "pid": None, "env_file": "", "log_file": "", "report_file": "", "mode": "run",
           "version": "", "args": "", "started": None, "ended": None, "rc": None, "status": "running",
           "steps": [], "checks": [], "preflight": None, "current": None}
    steps = {}
    run["tag"] = path.name[len("migrate-"):-len(".events")]
    try:
        lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
    except OSError:
        lines = []
    for line in lines:
        f = line.split("\t")
        if len(f) < 2:
            continue
        try:
            t = int(f[0])
        except ValueError:
            continue
        kind, a = f[1], f[2:]
        if kind == "start" and len(a) >= 5:
            run.update(pid=int(a[0]) if a[0].isdigit() else None, env_file=a[1], log_file=a[2],
                       report_file=a[3], mode=a[4], version=a[5] if len(a) > 5 else "",
                       args=a[6] if len(a) > 6 else "", started=t)
        elif kind == "plan" and len(a) >= 3:
            s = {"id": a[0], "title": a[2], "planned": a[1], "reason": a[3] if len(a) > 3 else "",
                 "state": "pending" if a[1] == "run" else "skipped", "started": None, "elapsed": None, "rc": None}
            steps[a[0]] = s
            run["steps"].append(s)
        elif kind == "preflight_start":
            run["preflight"] = {"state": "running", "started": t, "fail": 0, "warn": 0}
        elif kind == "preflight_end" and run["preflight"] is not None:
            run["preflight"].update(state="ok" if a and a[0] == "0" else "fail",
                                    fail=int(a[1]) if len(a) > 1 and a[1].isdigit() else 0,
                                    warn=int(a[2]) if len(a) > 2 and a[2].isdigit() else 0, ended=t)
        elif kind == "check" and len(a) >= 2:
            run["checks"].append({"level": a[0], "message": a[1]})
        elif kind == "step_start" and a:
            s = steps.get(a[0])
            if s is None:
                s = steps[a[0]] = {"id": a[0], "title": a[1] if len(a) > 1 else a[0], "planned": "run",
                                   "reason": "", "state": "pending", "started": None, "elapsed": None, "rc": None}
                run["steps"].append(s)
            s.update(state="running", started=t)
            run["current"] = a[0]
        elif kind == "step_end" and len(a) >= 2 and a[0] in steps:
            rc = int(a[1]) if a[1].lstrip("-").isdigit() else 1
            steps[a[0]].update(state="ok" if rc == 0 else "failed", rc=rc,
                               elapsed=int(a[2]) if len(a) > 2 and a[2].isdigit() else None)
            run["current"] = None
        elif kind == "step_skip" and a and a[0] in steps:
            steps[a[0]].update(state="skipped", reason=a[1] if len(a) > 1 else "")
        elif kind == "end":
            run["ended"] = t
            run["rc"] = int(a[0]) if a and a[0].lstrip("-").isdigit() else 1
    if run["rc"] is not None:
        run["status"] = "ok" if run["rc"] == 0 else ("stopped" if run["rc"] == 130 else "failed")
    elif not (run["pid"] and pid_alive(run["pid"])):
        run["status"] = "interrupted"
    if run["status"] != "running":
        for s in run["steps"]:
            if s["state"] == "running":
                s["state"] = "failed" if run["status"] != "stopped" else "stopped"
            elif s["state"] == "pending":
                s["state"] = "not-run"
        run["current"] = None
    run["counts"] = {k: sum(1 for s in run["steps"] if s["state"] == k)
                     for k in ("ok", "failed", "skipped", "pending", "running", "not-run", "stopped")}
    return run


def same_file(a, b):
    try:
        return os.path.realpath(a) == os.path.realpath(b)
    except (OSError, ValueError):
        return False


def list_runs(log_dir, env_path, limit=None):
    if not log_dir.is_dir():
        return []
    out = []
    for f in sorted(log_dir.glob("migrate-*.events"), reverse=True):
        try:
            with f.open(encoding="utf-8", errors="replace") as fh:
                first = fh.readline().split("\t")
        except OSError:
            continue
        if len(first) < 4 or first[1] != "start" or not same_file(first[3], env_path):
            continue
        run = parse_events(f)
        run.pop("checks", None)
        out.append(run)
        if limit and len(out) >= limit:
            break
    return out


def cut_utf8(data):
    """Decode DATA, holding back a trailing partial UTF-8 sequence.
    Returns (text, bytes consumed)."""
    try:
        return data.decode("utf-8"), len(data)
    except UnicodeDecodeError as e:
        if e.start >= len(data) - 3:
            return data[:e.start].decode("utf-8", "replace"), e.start
        return data.decode("utf-8", "replace"), len(data)


class Runs:
    def __init__(self):
        self.jobs = {}          # tag -> job dict
        self.rsync = {}         # rsync log path -> (offset, lines, last)
        self.lock = threading.Lock()

    def running_for(self, env_path, log_dir):
        with self.lock:
            for tag, job in self.jobs.items():
                if job["proc"].poll() is None and same_file(job["env"], env_path):
                    return tag
        for run in list_runs(log_dir, env_path, limit=5):
            if run["status"] == "running":
                return run["tag"]
        return None

    def start(self, pid, env_path, log_dir, args, mode):
        log_dir.mkdir(parents=True, exist_ok=True)
        with self.lock:
            tag = time.strftime("%Y-%m-%d_%H-%M-%S")
            n = 1
            while (log_dir / ("migrate-%s.events" % tag)).exists() or tag in self.jobs:
                n += 1
                tag = time.strftime("%Y-%m-%d_%H-%M-%S") + "-%d" % n
            out_path = log_dir / ("gui-%s.out" % tag)
            out = open(str(out_path), "wb")
            env = dict(CHILD_ENV, MIGRATE_RUN_TAG=tag, NO_COLOR="1")
            cmd = ["bash", str(MIGRATE), "--env", str(env_path)] + args
            proc = subprocess.Popen(cmd, cwd=str(ROOT), stdin=subprocess.DEVNULL, stdout=out,
                                    stderr=subprocess.STDOUT, env=env, start_new_session=True)
            out.close()
            job = {"proc": proc, "profile": pid, "env": str(env_path), "log_dir": log_dir, "tag": tag,
                   "out": out_path, "mode": mode, "args": " ".join(args)}
            self.jobs[tag] = job
        threading.Thread(target=self._finish, args=(job,), daemon=True).start()
        return tag

    def _finish(self, job):
        rc = job["proc"].wait()
        log_dir, tag = job["log_dir"], job["tag"]
        events = log_dir / ("migrate-%s.events" % tag)
        log = log_dir / ("migrate-%s.log" % tag)
        if not events.exists():
            # migrate.sh stopped before it set up logging (bad .env, ...):
            # keep its output and record the run so it shows in the history.
            now = int(time.time())
            events.write_text("%d\tstart\t%d\t%s\t%s\t\t%s\t\t%s\n%d\tend\t%d\n" % (
                now, job["proc"].pid, job["env"], log, job["mode"], job["args"], now, rc), encoding="utf-8")
        # Stop interrupts the whole process group, including the sed that
        # writes the log, so its buffered tail can be lost; the raw output
        # captured here is then the more complete copy.
        try:
            if log.exists() and log.stat().st_size >= job["out"].stat().st_size:
                job["out"].unlink()
            else:
                job["out"].replace(log)
        except OSError:
            pass

    def can_stop(self, tag, pid):
        """Runs this GUI started (now or before a restart) lead their own
        process group; terminal runs do not, and are left alone."""
        with self.lock:
            job = self.jobs.get(tag)
        if job:
            return job["proc"].poll() is None
        try:
            return bool(pid) and pid_alive(pid) and os.getpgid(pid) == pid
        except OSError:
            return False

    def stop(self, tag, pid):
        """Ctrl-C for the run: SIGINT to its process group, so migrate.sh's
        cleanup trap closes the tunnel; SIGTERM if it is still there 15s later."""
        with self.lock:
            job = self.jobs.get(tag)
        if job:
            pid = job["proc"].pid
        if not self.can_stop(tag, pid):
            raise ApiError(409, "That run was started from a terminal or has already finished")
        os.killpg(pid, signal.SIGINT)

        def escalate():
            if pid_alive(pid):
                try:
                    os.killpg(pid, signal.SIGTERM)
                except OSError:
                    pass
        threading.Timer(15, escalate).start()

    def output_path(self, log_dir, tag):
        with self.lock:
            job = self.jobs.get(tag)
        if job and job["out"].exists():
            return job["out"]
        out = log_dir / ("gui-%s.out" % tag)
        if out.exists():
            return out
        return log_dir / ("migrate-%s.log" % tag)

    def rsync_progress(self, path):
        """Files rsync has logged so far (counted incrementally)."""
        if not path.is_file():
            return None
        offset, lines, last = self.rsync.get(str(path), (0, 0, ""))
        size = path.stat().st_size
        if size < offset:
            offset, lines, last = 0, 0, ""
        if size > offset:
            with path.open("rb") as fh:
                fh.seek(offset)
                chunk = fh.read(min(size - offset, 8 * 1024 * 1024))
            cut = chunk.rfind(b"\n") + 1
            for raw in chunk[:cut].splitlines():
                m = re.search(rb"\] ([<>ch.*][fdLDS][^ ]*) (.+)$", raw)
                if m and m.group(1)[:1] in (b">", b"c") and m.group(1)[1:2] == b"f":
                    lines += 1
                    last = m.group(2).decode("utf-8", "replace")
            offset += cut
            self.rsync[str(path)] = (offset, lines, last)
        return {"files": lines, "last": last, "bytes": size}


# ------------------------------------------------------------------ app

class App:
    def __init__(self, token):
        self.token = token
        self.example = parse_example()
        self.profiles = Profiles(self.example)
        self.runs = Runs()
        self.schema = json.loads(SCHEMA_FILE.read_text(encoding="utf-8"))
        self.version = self._cmd(["--version"]).strip().split(" ")[-1]
        self.steps = self._steps()

    def _cmd(self, args):
        return subprocess.run(["bash", str(MIGRATE)] + args, cwd=str(ROOT), stdin=subprocess.DEVNULL,
                              stdout=subprocess.PIPE, stderr=subprocess.STDOUT, env=CHILD_ENV,
                              timeout=30).stdout.decode("utf-8", "replace")

    def _steps(self):
        steps = []
        for line in self._cmd(["--list-steps"]).splitlines()[1:]:
            parts = line.split(None, 3)
            if len(parts) == 4:
                steps.append({"id": parts[0], "mode": parts[1], "platforms": parts[2], "description": parts[3]})
        return steps

    def step_ids(self):
        return [s["id"] for s in self.steps]

    # -- handlers ---------------------------------------------------------

    def meta(self, q, body):
        return {"version": self.version, "root": str(ROOT), "steps": self.steps, "schema": self.schema,
                "example": self.example, "tests": TEST_IDS, "home": str(Path.home())}

    def list_profiles(self, q, body):
        out = []
        for pid in profile_ids():
            try:
                out.append(self.profiles.describe(pid))
            except ApiError:
                continue
        return {"profiles": out, "has_default": DEFAULT_ENV.is_file()}

    def get_profile(self, q, body, pid):
        data = self.profiles.load(pid)
        log_dir = self.profiles.log_dir(data["values"])
        return {"id": pid, "file": rel(data["path"]), "cli": cli_for(pid), "values": data["values"],
                "present": data["present"], "source_ok": data["source_rc"] == 0,
                "hooks": self.profiles.hook_info(pid, data["values"]),
                "log_dir": rel(log_dir), "running": self.runs.running_for(data["path"], log_dir)}

    def create_profile(self, q, body):
        name = (body.get("name") or "").strip().lower()
        pid = "default" if body.get("default") else name
        if pid != "default" and not PROFILE_RE.match(pid):
            raise ApiError(400, "Use lowercase letters, numbers, - and _ (max 48), starting with a letter or number")
        if pid == "default" and DEFAULT_ENV.exists():
            raise ApiError(409, ".env already exists; pick a name for a new migration instead")
        copy_from = body.get("copy_from") or None
        self.profiles.create(pid, copy_from)
        if body.get("values"):
            self.profiles.save(pid, body["values"], body.get("hooks"))
        return {"id": pid}

    def save_profile(self, q, body, pid):
        changed = self.profiles.save(pid, body.get("values"), body.get("hooks"))
        return {"changed": changed, "profile": self.get_profile(q, {}, pid)}

    def delete_profile(self, q, body, pid):
        if body.get("confirm") != pid:
            raise ApiError(400, "Type the migration name to confirm")
        self.profiles.delete(pid)
        return {"deleted": pid}

    def test(self, q, body, pid):
        targets = [t for t in (body.get("targets") or []) if t in TEST_IDS]
        if not targets:
            raise ApiError(400, "Nothing to test")
        if pid == "_new":
            pid = None
        name = self.profiles.temp_env(pid, body.get("values"))
        try:
            started = time.time()
            proc = subprocess.run(
                ["bash", str(MIGRATE), "--env", name, "--test", ",".join(targets), "--yes", "--plain"],
                cwd=str(ROOT), stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                env=CHILD_ENV, timeout=120, start_new_session=True)
            output = proc.stdout.decode("utf-8", "replace")
            rc = proc.returncode
        except subprocess.TimeoutExpired as e:
            output = (e.output or b"").decode("utf-8", "replace") + "\n[FAIL] Timed out after 120s"
            rc = 124
        finally:
            os.unlink(name)
        results = []
        for line in output.splitlines():
            m = re.match(r"^\s*\[(OK|FAIL|WARN|INFO)\]\s*(.*)$", line)
            if m:
                results.append({"level": m.group(1).lower(), "message": m.group(2).replace(name, "<env>")})
        return {"ok": rc == 0, "rc": rc, "results": results, "seconds": round(time.time() - started, 1),
                "output": output.replace(name, "<env>")}

    def start_run(self, q, body, pid):
        data = self.profiles.load(pid)
        v = data["values"]
        log_dir = self.profiles.log_dir(v)
        if self.runs.running_for(data["path"], log_dir):
            raise ApiError(409, "This migration is already running")
        mode = body.get("mode") or "run"
        ids = set(self.step_ids())
        lists = {}
        for k in ("skip", "only", "with"):
            vals = [s for s in (body.get(k) or []) if s]
            bad = [s for s in vals if s not in ids]
            if bad:
                raise ApiError(400, "Unknown step id(s): %s" % ", ".join(bad))
            lists[k] = vals
        if mode == "check":
            args = ["--check"]
        elif mode in ("run", "dry-run"):
            args = ["--yes"]
            if mode == "dry-run":
                args.append("--dry-run")
            for k in ("skip", "only", "with"):
                if lists[k]:
                    args += ["--" + k, ",".join(lists[k])]
            wants_clear = "clear-web-root" in lists["with"] or "clear-web-root" in lists["only"] \
                or v.get("run_clear_web_root", "").lower() in ("true", "1", "yes", "y", "on")
            if wants_clear and "clear-web-root" not in lists["skip"] and mode == "run":
                expected = os.path.basename((v.get("local_web_root") or "").rstrip("/"))
                if body.get("confirm_clear") != expected:
                    raise ApiError(400, "Type the web root folder name (%s) to confirm clearing it" % expected)
        else:
            raise ApiError(400, "Unknown mode")
        tag = self.runs.start(pid, data["path"], log_dir, args, mode)
        return {"tag": tag}

    def list_profile_runs(self, q, body, pid):
        data = self.profiles.load(pid)
        log_dir = self.profiles.log_dir(data["values"])
        return {"runs": list_runs(log_dir, data["path"]), "log_dir": rel(log_dir)}

    def _run_files(self, log_dir, tag):
        names = {"log": "migrate-%s.log" % tag, "report": "migrate-report-%s.txt" % tag,
                 "rsync": "rsync-%s.log" % tag, "events": "migrate-%s.events" % tag}
        return {k: log_dir / n for k, n in names.items()}

    def get_run(self, q, body, pid, tag):
        if not TAG_RE.match(tag):
            raise ApiError(400, "Bad run id")
        data = self.profiles.load(pid)
        log_dir = self.profiles.log_dir(data["values"])
        files = self._run_files(log_dir, tag)
        with self.runs.lock:
            job = self.runs.jobs.get(tag)
        if files["events"].exists():
            run = parse_events(files["events"])
        elif job and job["proc"].poll() is None:
            # just launched: bash has not written its first event yet
            run = parse_events(files["events"])
            run.update(status="running", pid=job["proc"].pid, mode=job["mode"], args=job["args"],
                       started=int(time.time()))
        else:
            raise ApiError(404, "Run not found")
        run["files"] = {k: {"name": p.name, "size": p.stat().st_size} for k, p in files.items() if p.exists()}
        run["now"] = int(time.time())
        run["stoppable"] = run["status"] == "running" and self.runs.can_stop(tag, run["pid"])
        if run["current"] == "sync-files" or (run["status"] == "running" and files["rsync"].exists()):
            run["rsync"] = self.runs.rsync_progress(files["rsync"])
        # output since OFFSET (or the tail when OFFSET is -1)
        out_path = self.runs.output_path(log_dir, tag)
        offset = int((q.get("offset") or ["-1"])[0])
        run["output"], run["offset"], run["truncated"] = "", 0, False
        if out_path.exists():
            size = out_path.stat().st_size
            if offset < 0 or offset > size:
                offset = max(0, size - POLL_LIMIT)
                run["truncated"] = offset > 0
            with out_path.open("rb") as fh:
                fh.seek(offset)
                chunk = fh.read(POLL_LIMIT)
            run["output"], used = cut_utf8(chunk)
            run["offset"] = offset + used
            run["source"] = out_path.name
        stale = log_dir / ("gui-%s.out" % tag)
        if run["status"] != "running" and stale.exists() and files["log"].exists() and not run["stoppable"]:
            stale.unlink()  # left behind when the GUI was closed during the run
        return run

    def stop_run(self, q, body, pid, tag):
        if not TAG_RE.match(tag):
            raise ApiError(400, "Bad run id")
        data = self.profiles.load(pid)
        events = self._run_files(self.profiles.log_dir(data["values"]), tag)["events"]
        if not events.exists():
            raise ApiError(404, "Run not found")
        self.runs.stop(tag, parse_events(events)["pid"])
        return {"stopping": tag}

    def run_file(self, q, body, pid, tag, kind):
        if not TAG_RE.match(tag):
            raise ApiError(400, "Bad run id")
        data = self.profiles.load(pid)
        files = self._run_files(self.profiles.log_dir(data["values"]), tag)
        path = files.get(kind)
        if path is None or not path.exists():
            raise ApiError(404, "File not found")
        return path

    def log_files(self, q, body, pid):
        data = self.profiles.load(pid)
        log_dir = self.profiles.log_dir(data["values"])
        files = []
        if log_dir.is_dir():
            for f in sorted(log_dir.iterdir(), key=lambda p: p.stat().st_mtime, reverse=True):
                if f.is_file() and not f.name.startswith("."):
                    st = f.stat()
                    files.append({"name": f.name, "size": st.st_size, "mtime": int(st.st_mtime)})
        return {"log_dir": rel(log_dir), "files": files[:500]}

    def log_file(self, q, body, pid, name):
        data = self.profiles.load(pid)
        log_dir = self.profiles.log_dir(data["values"])
        if "/" in name or name.startswith("."):
            raise ApiError(400, "Bad file name")
        path = log_dir / name
        if not path.is_file():
            raise ApiError(404, "File not found")
        return path

    def ssh_keys(self, q, body):
        d = Path.home() / ".ssh"
        keys = []
        if d.is_dir():
            for f in sorted(d.iterdir()):
                if not f.is_file() or f.suffix == ".pub" or f.name in ("known_hosts", "known_hosts.old",
                                                                      "config", "authorized_keys", "environment"):
                    continue
                try:
                    head = f.open("rb").read(64)
                except OSError:
                    continue
                if b"PRIVATE KEY" not in head:
                    continue
                mode = f.stat().st_mode & 0o777
                keys.append({"path": "~/.ssh/" + f.name, "mode": oct(mode)[2:], "loose": bool(mode & 0o077),
                             "has_pub": (d / (f.name + ".pub")).exists()})
        return {"keys": keys}


ROUTES = [
    ("GET", r"/api/meta", "meta"),
    ("GET", r"/api/ssh-keys", "ssh_keys"),
    ("GET", r"/api/profiles", "list_profiles"),
    ("POST", r"/api/profiles", "create_profile"),
    ("GET", r"/api/profiles/([\w-]+)", "get_profile"),
    ("PUT", r"/api/profiles/([\w-]+)", "save_profile"),
    ("DELETE", r"/api/profiles/([\w-]+)", "delete_profile"),
    ("POST", r"/api/profiles/([\w-]+)/test", "test"),
    ("POST", r"/api/profiles/([\w-]+)/runs", "start_run"),
    ("GET", r"/api/profiles/([\w-]+)/runs", "list_profile_runs"),
    ("GET", r"/api/profiles/([\w-]+)/runs/([\w.-]+)", "get_run"),
    ("POST", r"/api/profiles/([\w-]+)/runs/([\w.-]+)/stop", "stop_run"),
    ("GET", r"/api/profiles/([\w-]+)/runs/([\w.-]+)/files/(\w+)", "run_file"),
    ("GET", r"/api/profiles/([\w-]+)/logs", "log_files"),
    ("GET", r"/api/profiles/([\w-]+)/logs/([^/]+)", "log_file"),
]
ROUTES = [(m, re.compile("^" + p + "$"), h) for m, p, h in ROUTES]


class Handler(BaseHTTPRequestHandler):
    server_version = "ums-gui"
    app = None  # set in main()

    def log_message(self, fmt, *args):
        if os.environ.get("UMS_GUI_DEBUG"):
            sys.stderr.write("%s - %s\n" % (self.address_string(), fmt % args))

    def _send(self, status, body, ctype="application/json; charset=utf-8", extra=None):
        data = body if isinstance(body, bytes) else json.dumps(body).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Referrer-Policy", "no-referrer")
        if ctype.startswith("text/html"):
            self.send_header("Content-Security-Policy",
                             "default-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; "
                             "frame-ancestors 'none'")
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(data)

    def _host_ok(self):
        host = (self.headers.get("Host") or "").rsplit(":", 1)[0].strip("[]")
        return host in ("127.0.0.1", "localhost", "::1") or host == self.server.server_address[0]

    def _dispatch(self):
        if not self._host_ok():
            return self._send(403, {"error": "Bad Host header"})
        url = urlparse(self.path)
        if not url.path.startswith("/api/"):
            if self.command not in ("GET", "HEAD") or url.path not in STATIC_FILES:
                return self._send(404, {"error": "Not found"})
            name, ctype = STATIC_FILES[url.path]
            return self._send(200, (STATIC_DIR / name).read_bytes(), ctype)
        q = parse_qs(url.query)
        token = self.headers.get("X-UMS-Token") or (q.get("token") or [""])[0]
        if not secrets.compare_digest(token, self.app.token):
            return self._send(401, {"error": "Missing or wrong token. Open the URL printed by ./gui.sh."})
        for method, rx, handler in ROUTES:
            m = rx.match(url.path)
            if m and method == self.command:
                break
        else:
            return self._send(404, {"error": "Not found"})
        body = {}
        if self.command in ("POST", "PUT", "DELETE"):
            length = int(self.headers.get("Content-Length") or 0)
            if length:
                if "application/json" not in (self.headers.get("Content-Type") or ""):
                    return self._send(415, {"error": "JSON only"})
                try:
                    body = json.loads(self.rfile.read(length).decode("utf-8"))
                except ValueError:
                    return self._send(400, {"error": "Invalid JSON"})
        try:
            result = getattr(self.app, handler)(q, body, *m.groups())
        except ApiError as e:
            return self._send(e.status, {"error": e.message})
        except subprocess.TimeoutExpired:
            return self._send(504, {"error": "A helper command timed out"})
        except Exception as e:  # keep the server alive and tell the page
            return self._send(500, {"error": "%s: %s" % (type(e).__name__, e)})
        if isinstance(result, Path):
            return self._send_file(result, q)
        return self._send(200, result)

    def _send_file(self, path, q):
        size = path.stat().st_size
        if (q.get("download") or [""])[0]:
            data = path.read_bytes()
            return self._send(200, data, "application/octet-stream",
                              {"Content-Disposition": 'attachment; filename="%s"' % path.name})
        limit = 2 * 1024 * 1024
        with path.open("rb") as fh:
            if size > limit:
                fh.seek(size - limit)
            data = fh.read()
        extra = {"X-Truncated": "1" if size > limit else "0", "X-File-Size": str(size)}
        return self._send(200, data, "text/plain; charset=utf-8", extra)

    do_GET = do_HEAD = do_POST = do_PUT = do_DELETE = _dispatch


def main(argv=None):
    ap = argparse.ArgumentParser(description="Local web GUI for universal-migrate-site-script")
    ap.add_argument("--port", type=int, default=int(os.environ.get("UMS_GUI_PORT", "8765")))
    ap.add_argument("--host", default="127.0.0.1",
                    help="address to bind (default 127.0.0.1; anything else exposes your credentials)")
    ap.add_argument("--no-browser", action="store_true", help="do not open a browser window")
    ap.add_argument("--token", default=os.environ.get("UMS_GUI_TOKEN") or secrets.token_urlsafe(18),
                    help=argparse.SUPPRESS)
    opts = ap.parse_args(argv)
    if sys.version_info < (3, 8):
        sys.exit("The GUI needs Python 3.8 or newer.")
    Handler.app = App(opts.token)
    server = None
    for port in range(opts.port, opts.port + 20):
        try:
            server = ThreadingHTTPServer((opts.host, port), Handler)
            break
        except OSError as e:
            if e.errno != errno.EADDRINUSE:
                raise
    if server is None:
        sys.exit("No free port in %d-%d" % (opts.port, opts.port + 19))
    server.daemon_threads = True
    host = opts.host if opts.host not in ("0.0.0.0", "::") else "127.0.0.1"
    url = "http://%s:%d/#token=%s" % (host, server.server_address[1], opts.token)
    if opts.host not in ("127.0.0.1", "localhost", "::1"):
        print("WARNING: listening on %s. Anyone who can reach it and has the token can read your credentials "
              "and run migrations." % opts.host, file=sys.stderr)
    print("universal-migrate-site-script GUI %s" % Handler.app.version)
    print("Open: %s" % url)
    print("Press Ctrl-C to stop the GUI (running migrations keep going).", flush=True)
    if not opts.no_browser:
        threading.Timer(0.5, lambda: webbrowser.open(url)).start()
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nStopped.")
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
