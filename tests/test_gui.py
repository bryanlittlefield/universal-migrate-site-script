"""Tests for gui/server.py (standard library only).

    python3 -m unittest discover -s tests -p 'test_gui.py'

Profiles are created in a temporary directory: the module's path globals are
pointed there, so nothing touches the real .env or sites/.
"""

import http.client
import json
import os
import shutil
import sys
import tempfile
import threading
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "gui"))
import server  # noqa: E402


class EnvWriterTest(unittest.TestCase):
    def test_replaces_values_and_keeps_comment_column(self):
        text = "a='1'                # first\nb=''\n"
        out = server.set_env_values(text, {"a": "long value here", "b": "x"})
        self.assertEqual(out, "a='long value here'  # first\nb='x'\n")

    def test_quotes_anything_bash_would_mangle(self):
        out = server.set_env_values("p=''\n", {"p": "pa$s wo#r'd \"q\" `x`"})
        vals = self._source(out, ["p"])
        self.assertEqual(vals["p"], "pa$s wo#r'd \"q\" `x`")

    def test_replaces_every_occurrence_and_multiline_values(self):
        text = "k='a\nb'\nother=1\nexport k=2 # again\n"
        out = server.set_env_values(text, {"k": "z"})
        self.assertEqual(out, "k='z'\nother=1\nexport k='z' # again\n")

    def test_appends_missing_keys(self):
        out = server.set_env_values("a=1", {"new_key": "v"})
        self.assertTrue(out.startswith("a=1\n"))
        self.assertIn("Added by the GUI", out)
        self.assertTrue(out.endswith("new_key='v'\n"))

    def test_rejects_bad_keys(self):
        with self.assertRaises(server.ApiError):
            server.set_env_values("", {"bad-key": "x"})

    def test_parse_example_reads_keys_defaults_and_comments(self):
        ex = server.parse_example()
        self.assertIn("remote_ssh_host", ex["keys"])
        self.assertEqual(ex["defaults"]["remote_ssh_port"], "22")
        self.assertEqual(ex["defaults"]["db_export_method"], "tunnel")
        self.assertIn("remote: run mysqldump", ex["comments"]["db_export_method"])
        self.assertEqual(ex["sections"]["import_db_name"], "Local server (destination)")

    def _source(self, text, keys):
        fd, name = tempfile.mkstemp(suffix=".env")
        with os.fdopen(fd, "w") as fh:
            fh.write(text)
        try:
            return server.source_env(name, keys)[0]
        finally:
            os.unlink(name)


class EventsTest(unittest.TestCase):
    def setUp(self):
        self.dir = Path(tempfile.mkdtemp())

    def tearDown(self):
        shutil.rmtree(str(self.dir))

    def write(self, tag, lines):
        p = self.dir / ("migrate-%s.events" % tag)
        p.write_text("".join("\t".join(map(str, l)) + "\n" for l in lines))
        return p

    def test_parses_a_finished_run(self):
        p = self.write("t1", [
            (100, "start", 999999, "/x/.env", "/l/log", "/l/rep", "run", "1.2.0", "--yes"),
            (100, "plan", "sync-files", "run", "Sync files", ""),
            (100, "plan", "verify", "skip", "Verify", "--skip"),
            (101, "preflight_start"), (101, "check", "ok", "SSH fine"), (102, "preflight_end", 0, 0, 1),
            (102, "step_start", "sync-files", "Sync files"), (110, "step_end", "sync-files", 0, 8),
            (110, "step_skip", "verify", "--skip"), (111, "end", 0),
        ])
        run = server.parse_events(p)
        self.assertEqual(run["tag"], "t1")
        self.assertEqual(run["status"], "ok")
        self.assertEqual(run["args"], "--yes")
        self.assertEqual([s["state"] for s in run["steps"]], ["ok", "skipped"])
        self.assertEqual(run["steps"][0]["elapsed"], 8)
        self.assertEqual(run["preflight"]["state"], "ok")
        self.assertEqual(run["checks"], [{"level": "ok", "message": "SSH fine"}])

    def test_dead_process_without_end_is_interrupted(self):
        p = self.write("t2", [(1, "start", 2 ** 22 + 12345, "/x/.env", "l", "r", "run"),
                              (1, "plan", "a", "run", "A", ""), (2, "step_start", "a", "A")])
        run = server.parse_events(p)
        self.assertEqual(run["status"], "interrupted")
        self.assertEqual(run["steps"][0]["state"], "failed")

    def test_ctrl_c_is_stopped_and_unreached_steps_not_run(self):
        p = self.write("t3", [(1, "start", 1, "/x/.env", "l", "r", "run"), (1, "plan", "a", "run", "A", ""),
                              (1, "plan", "b", "run", "B", ""), (2, "step_start", "a", "A"), (3, "end", 130)])
        run = server.parse_events(p)
        self.assertEqual(run["status"], "stopped")
        self.assertEqual([s["state"] for s in run["steps"]], ["stopped", "not-run"])

    def test_list_runs_filters_by_env_file(self):
        env = self.dir / "a.env"
        env.write_text("")
        self.write("2026-01-01_00-00-01", [(1, "start", 1, str(env), "l", "r", "check"), (2, "end", 0)])
        self.write("2026-01-01_00-00-02", [(1, "start", 1, "/other.env", "l", "r", "run"), (2, "end", 0)])
        runs = server.list_runs(self.dir, env)
        self.assertEqual([r["tag"] for r in runs], ["2026-01-01_00-00-01"])

    def test_cut_utf8_holds_back_a_partial_character(self):
        data = "ok ✅".encode("utf-8")
        self.assertEqual(server.cut_utf8(data), ("ok ✅", len(data)))
        self.assertEqual(server.cut_utf8(data[:-1]), ("ok ", 3))


class ApiTest(unittest.TestCase):
    """The HTTP API end to end, against a throwaway root directory."""

    @classmethod
    def setUpClass(cls):
        cls.tmp = Path(tempfile.mkdtemp())
        cls.saved = {k: getattr(server, k) for k in ("ROOT", "DEFAULT_ENV", "SITES_DIR", "HOOKS_DIR")}
        server.ROOT = cls.tmp
        server.DEFAULT_ENV = cls.tmp / ".env"
        server.SITES_DIR = cls.tmp / "sites"
        server.HOOKS_DIR = cls.tmp / "hooks"
        server.Handler.app = server.App("tok")
        cls.httpd = server.ThreadingHTTPServer(("127.0.0.1", 0), server.Handler)
        cls.port = cls.httpd.server_address[1]
        threading.Thread(target=cls.httpd.serve_forever, daemon=True).start()

    @classmethod
    def tearDownClass(cls):
        cls.httpd.shutdown()
        cls.httpd.server_close()
        for k, v in cls.saved.items():
            setattr(server, k, v)
        shutil.rmtree(str(cls.tmp))

    def call(self, method, path, body=None, token="tok", host=None):
        conn = http.client.HTTPConnection("127.0.0.1", self.port, timeout=30)
        headers = {"X-UMS-Token": token} if token else {}
        if host:
            headers["Host"] = host
        data = None
        if body is not None:
            data = json.dumps(body)
            headers["Content-Type"] = "application/json"
        conn.request(method, path, data, headers)
        res = conn.getresponse()
        raw = res.read()
        conn.close()
        try:
            return res.status, json.loads(raw.decode("utf-8"))
        except ValueError:
            return res.status, raw.decode("utf-8")

    def test_requires_token_and_local_host(self):
        self.assertEqual(self.call("GET", "/api/meta", token="")[0], 401)
        self.assertEqual(self.call("GET", "/api/meta", token="wrong")[0], 401)
        self.assertEqual(self.call("GET", "/api/meta", host="evil.example")[0], 403)
        status, page = self.call("GET", "/", token="")
        self.assertEqual(status, 200)
        self.assertIn("app.js", page)
        self.assertEqual(self.call("GET", "/../server.py", token="")[0], 404)

    def test_meta_lists_steps_including_hooks(self):
        status, meta = self.call("GET", "/api/meta")
        self.assertEqual(status, 200)
        ids = [s["id"] for s in meta["steps"]]
        self.assertEqual(ids[0], "before-run")
        self.assertEqual(ids[-1], "after-run")
        self.assertIn("ssh", meta["tests"])
        keys = {f["key"] for sec in meta["schema"]["sections"] for f in sec["fields"]}
        self.assertTrue(keys - {"_ssh_auth"} <= set(meta["example"]["keys"]), keys - set(meta["example"]["keys"]))

    def test_profile_lifecycle(self):
        status, r = self.call("POST", "/api/profiles", {"name": "Bad Name!"})
        self.assertEqual(status, 400)
        status, r = self.call("POST", "/api/profiles", {"name": "site-a"})
        self.assertEqual((status, r), (200, {"id": "site-a"}))
        env = self.tmp / "sites" / "site-a.env"
        self.assertEqual(oct(env.stat().st_mode & 0o777), "0o600")
        self.assertEqual(self.call("POST", "/api/profiles", {"name": "site-a"})[0], 409)

        status, r = self.call("PUT", "/api/profiles/site-a", {
            "values": {"remote_ssh_host": "h.example", "export_db_pass": "a'b c", "remote_ssh_port": "22"},
            "hooks": {"before": "echo hi", "after": ""}})
        self.assertEqual(status, 200)
        self.assertEqual(r["changed"], ["before_run_hook", "export_db_pass", "remote_ssh_host"])
        p = r["profile"]
        self.assertEqual(p["values"]["export_db_pass"], "a'b c")
        self.assertEqual(p["hooks"]["before"]["kind"], "file")
        self.assertEqual(p["hooks"]["before"]["file"], "hooks/site-a/before-run.sh")
        self.assertEqual((self.tmp / "hooks/site-a/before-run.sh").read_text(), "echo hi\n")
        self.assertIn("# IP or hostname", env.read_text())  # comments from .env.example survive

        status, lst = self.call("GET", "/api/profiles")
        self.assertIn("site-a", [x["id"] for x in lst["profiles"]])
        self.assertEqual(self.call("POST", "/api/profiles", {"name": "site-b", "copy_from": "site-a"})[0], 200)
        self.assertEqual(self.call("GET", "/api/profiles/site-b")[1]["values"]["remote_ssh_host"], "h.example")

        self.assertEqual(self.call("DELETE", "/api/profiles/site-b", {"confirm": "nope"})[0], 400)
        self.assertEqual(self.call("DELETE", "/api/profiles/site-b", {"confirm": "site-b"})[0], 200)
        self.assertFalse((self.tmp / "sites" / "site-b.env").exists())
        self.assertEqual(self.call("GET", "/api/profiles/site-b")[0], 404)

    def test_run_validation(self):
        self.call("POST", "/api/profiles", {"name": "site-c"})
        self.call("PUT", "/api/profiles/site-c", {"values": {"local_web_root": "/srv/www/site-c"}})
        status, r = self.call("POST", "/api/profiles/site-c/runs", {"mode": "run", "skip": ["nope"]})
        self.assertEqual(status, 400)
        status, r = self.call("POST", "/api/profiles/site-c/runs", {"mode": "run", "with": ["clear-web-root"]})
        self.assertEqual(status, 400)
        self.assertIn("site-c", r["error"])
        self.assertEqual(self.call("POST", "/api/profiles/site-c/runs", {"mode": "explode"})[0], 400)
        self.assertEqual(self.call("GET", "/api/profiles/site-c/runs/..%2Fx")[0], 404)

    def test_connection_test_uses_unsaved_values(self):
        self.call("POST", "/api/profiles", {"name": "site-d"})
        status, r = self.call("POST", "/api/profiles/site-d/test",
                              {"targets": ["ssh"], "values": {"remote_ssh_host": "h", "remote_ssh_user": "u",
                                                              "remote_ssh_web_root": "/w", "remote_ssh_key": "/no/such/key"}})
        self.assertEqual(status, 200)
        self.assertFalse(r["ok"])
        self.assertEqual(r["results"], [{"level": "fail", "message": "remote_ssh_key not found: /no/such/key"}])
        self.assertEqual(self.call("POST", "/api/profiles/site-d/test", {"targets": ["rm -rf"]})[0], 400)


if __name__ == "__main__":
    unittest.main()
