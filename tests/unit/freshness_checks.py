"""Hermetic tests; no live package, Docker, systemd or registry operations."""
import contextlib
import fcntl
import io
import json
from pathlib import Path
import runpy
import shutil
import subprocess
import tempfile
import time
import types
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
fresh = types.ModuleType("freshness")
fresh.__dict__.update(runpy.run_path(str(ROOT / "common/freshness")))
# Functions from runpy share their original globals.
GLOBALS = fresh.main.__globals__


class FreshnessTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)

    def report(self):
        return {"schema": 1, "checked_at": int(time.time()), "errors": [], "drift": [],
                "releases": [], "os": {"updates": 0}, "reboot": "not-required"}

    def invoke(self, *argv):
        out, err = io.StringIO(), io.StringIO()
        with patch("sys.argv", ["freshness", *map(str, argv)]), contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            rc = fresh.main()
        return rc, out.getvalue(), err.getvalue()

    def test_check_is_read_only_and_does_not_execute_commands(self):
        path = self.root / "report.json"
        path.write_text(json.dumps(self.report()))
        before = path.stat().st_mtime_ns, path.read_bytes(), sorted(self.root.iterdir())
        with patch.dict(GLOBALS, {"run": lambda *a, **k: self.fail("executed command"),
                                  "collect": lambda *a: self.fail("collected data")}):
            for flag in ("--summary", "--json"):
                rc, _, _ = self.invoke("--check", "--state", path, flag)
                self.assertEqual(rc, 0)
        self.assertEqual(before, (path.stat().st_mtime_ns, path.read_bytes(), sorted(self.root.iterdir())))

    def test_missing_and_invalid_cache_fail_without_creating_state(self):
        path = self.root / "missing" / "report.json"
        self.assertEqual(self.invoke("--check", "--state", path)[0], 2)
        self.assertFalse(path.parent.exists())
        path = self.root / "bad.json"
        path.write_text('{"schema":1}')
        self.assertEqual(self.invoke("--check", "--state", path)[0], 2)
        report = self.report()
        report["drift"] = ["malformed"]
        path.write_text(json.dumps(report))
        self.assertEqual(self.invoke("--check", "--state", path)[0], 2)

    def test_status_stale_errors_and_unknown(self):
        report = self.report()
        now = report["checked_at"]
        self.assertEqual(fresh.report_status(report, now)[0], 0)
        self.assertEqual(fresh.report_status(report, now + 37 * 3600)[0], 1)
        report["errors"].append("registry unavailable")
        self.assertEqual(fresh.report_status(report, now)[0], 2)
        report["errors"].clear()
        report["reboot"] = "unknown"
        self.assertEqual(fresh.report_status(report, now)[0], 1)
        with self.assertRaises(fresh.CheckError):
            fresh.report_status(report, now - 1)

    def test_atomic_save_keeps_previous_report_on_failure(self):
        path = self.root / "report.json"
        fresh.save_report(path, self.report())
        old = path.read_bytes()
        self.assertEqual(path.stat().st_mode & 0o777, 0o644)
        with patch("os.replace", side_effect=OSError("failure")):
            with self.assertRaises(OSError):
                fresh.save_report(path, {"changed": True})
        self.assertEqual(path.read_bytes(), old)
        self.assertEqual([p.name for p in self.root.iterdir()], ["report.json"])

    def test_refresh_lock_and_package_failure_remain_visible(self):
        state = self.root / "report.json"
        repo = self.root / "repo"
        with patch("os.geteuid", return_value=0):
            with (self.root / ".refresh.lock").open("a") as lock:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                self.assertEqual(self.invoke("--refresh", "--repo", repo, "--state", state)[0], 2)
        self.assertFalse(state.exists())
        def unavailable():
            raise fresh.CheckError("metadata unavailable")
        with patch.dict(GLOBALS, {"packages": unavailable, "reboot_state": lambda: "unknown",
                                  "drift": lambda repo: ([], [])}):
            report = fresh.collect(repo)
        self.assertIn("os: metadata unavailable", report["errors"])
        self.assertEqual(fresh.report_status(report)[0], 2)

    def test_dnf_exit_100_is_updates_not_failure(self):
        def command(argv, **kwargs):
            text = ("kernel-core.aarch64 6.1 repo\nfoo.noarch 2.0 repo\n" if "check-update" in argv
                    else "RLSA-2026:1 Important/Sec. foo-2.0.noarch\n")
            return subprocess.CompletedProcess(argv, 100 if "check-update" in argv else 0, text, "")
        with patch("shutil.which", return_value="/usr/bin/dnf"), patch.dict(GLOBALS, {"run": command}):
            result = fresh.packages()
        self.assertEqual(result["updates"], 2)
        self.assertEqual(result["security_advisories"], 1)

    def test_release_candidates_separate_major_and_ignore_prereleases(self):
        data = {"results": [{"name": name} for name in ("v1.2.4", "v2.0.0", "v9.0.0-rc1", "latest")]}
        with patch("urllib.request.urlopen", return_value=io.BytesIO(json.dumps(data).encode())):
            result = fresh.hub_tags("grafana/alloy:v1.2.3")
        self.assertEqual(result["same_major"], "v1.2.4")
        self.assertEqual(result["newest_sampled"], "v2.0.0")
        with self.assertRaises(fresh.CheckError):
            fresh.hub_tags("example.org/private/image:1.2.3")

    def test_run_never_discloses_failed_command_output(self):
        result = subprocess.CompletedProcess(["docker"], 1, "sensitive", "sensitive")
        with patch("subprocess.run", return_value=result), self.assertRaises(fresh.CheckError) as cm:
            fresh.run(["docker"])
        self.assertNotIn("sensitive", str(cm.exception))

    def test_bridge_rendering_and_file_difference_do_not_write(self):
        repo = self.root / "repo"
        source = repo / "runner/stacks/npm-cache"
        target = self.root / "opt/npm-cache"
        source.mkdir(parents=True)
        target.mkdir(parents=True)
        for name in ("config.yaml", "docker-compose.yml"):
            (source / name).write_text("listen: 172.17.0.1:4873\n")
            (target / name).write_text("listen: 172.18.0.1:4873\n")
        (target / ".env").write_text("sensitive")
        with patch.dict(GLOBALS, {"bridge_address": lambda: "172.18.0.1",
                                  "runtime_drift": lambda *a: None}):
            self.assertEqual(fresh.drift(repo, self.root)[0], [])
            (target / "config.yaml").write_text("changed")
            findings, _ = fresh.drift(repo, self.root)
            self.assertEqual(len(findings), 1)
            self.assertNotIn("changed", json.dumps(findings))
            self.assertNotIn("sensitive", json.dumps(findings))
            self.assertEqual((target / "config.yaml").read_text(), "changed")

    def test_missing_repo_is_error(self):
        findings, _ = fresh.drift(self.root, self.root)
        self.assertEqual(findings[0]["level"], "error")

    def test_monitoring_generated_jobs_and_datasource_are_normalized(self):
        repo = self.root / "repo"
        for name in ("monitoring", "logging", "registry-cache"):
            source = repo / "runner/stacks" / name
            source.parent.mkdir(parents=True, exist_ok=True)
            shutil.copytree(ROOT / "runner/stacks" / name, source)
            target = self.root / "opt" / name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copytree(source, target)
        prom = self.root / "opt/monitoring/prometheus/prometheus.yml"
        for job, port in (("registry-cache", 5001), ("loki", 3100), ("alloy", 12345)):
            with prom.open("a") as stream:
                stream.write(f'  - job_name: {job}\n    static_configs:\n      - targets: ["127.0.0.1:{port}"]\n')
        shutil.copyfile(repo / "runner/stacks/logging/grafana-datasource.yml",
                        self.root / "opt/monitoring/grafana/provisioning/datasources/loki.yml")
        with patch.dict(GLOBALS, {"runtime_drift": lambda *a: None}):
            self.assertEqual(fresh.drift(repo, self.root)[0], [])

    def test_health_reads_cache_and_warns_for_missing_required_timers(self):
        text = (ROOT / "common/health").read_text()
        def function(name):
            start = text.index(f"{name}() {{")
            return text[start:text.index("\n}\n", start) + 3]
        setup = r'''
PROFILE=runner
is_runner() { return 0; }
unit_exists() { return 1; }
have() { return 0; }
section() { :; }
warn() { printf 'WARN %s\n' "$*"; }
ok() { printf 'OK %s\n' "$*"; }
skip() { :; }
info() { :; }
'''
        # Do not run real systemd, Docker, registry, or package-manager commands.
        script = setup + function("check_services") + "\ncheck_services\n"
        result = subprocess.run(["bash", "-c", script], capture_output=True, text=True, check=True)
        self.assertIn("runner-engine-update.timer missing", result.stdout)
        self.assertNotIn("ci-image-prewarm.timer missing", result.stdout)
        cached = function("check_freshness").replace(
            '[[ -f /etc/server-freshness/repo ]] || return 0', ":")
        script = setup + "\nfreshness() { printf 'cached report'; return 1; }\n"
        script += "timeout() { shift; \"$@\"; }\n" + cached + "\ncheck_freshness\n"
        result = subprocess.run(["bash", "-c", script], capture_output=True, text=True, check=True)
        self.assertIn("WARN cached report", result.stdout)
        self.assertIn("server-freshness.timer missing", result.stdout)
        self.assertNotIn("--refresh", result.stdout)

    def test_runtime_memory_difference_and_missing_container(self):
        def command(argv, **kwargs):
            if "compose" in argv:
                data = {"name": "npm-cache", "services": {
                    "verdaccio": {"image": "verdaccio/verdaccio:7.0.2", "mem_limit": 1073741824},
                    "missing": {"image": "test:1.0.0"}}}
                return subprocess.CompletedProcess(argv, 0, json.dumps(data), "")
            text = "id\n" if "ps" in argv else ('{"com.docker.compose.service":"verdaccio"}|'
                                               '"verdaccio/verdaccio:7.0.2"|268435456|running\n')
            return subprocess.CompletedProcess(argv, 0, text, "")
        findings = []
        with patch.dict(GLOBALS, {"run": command}):
            fresh.runtime_drift(self.root, findings)
        self.assertEqual(len(findings), 2)
        self.assertIn("memory", findings[0]["detail"])
        self.assertEqual(findings[1]["detail"], "container missing")


if __name__ == "__main__":
    unittest.main()
