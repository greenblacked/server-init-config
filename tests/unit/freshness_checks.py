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

    def test_diff_compares_rendered_files_without_runtime_or_writes(self):
        repo = self.root / "repo"
        source = repo / "runner/stacks/npm-cache"
        target = self.root / "opt/npm-cache"
        source.mkdir(parents=True)
        target.mkdir(parents=True)
        for name in ("config.yaml", "docker-compose.yml"):
            (source / name).write_text("listen: 172.17.0.1:4873\n")
            (target / name).write_text("listen: 172.18.0.1:4873\n")
        (target / ".env").write_text("fixture-not-for-output")
        with patch.dict(GLOBALS, {"bridge_address": lambda: "172.18.0.1",
                                  "runtime_drift": lambda *_: self.fail("called runtime drift")}):
            self.assertEqual(self.invoke("--drift", "--diff", "--repo", repo, "--root", self.root), (0, "", ""))
            (target / "config.yaml").write_text("listen: changed")
            rc, out, err = self.invoke("--drift", "--diff", "--repo", repo, "--root", self.root)
            self.assertEqual((rc, err), (1, ""))
            self.assertIn("-listen: 172.18.0.1:4873", out)
            self.assertIn("+listen: changed\n\\ No newline at end of file", out)
            self.assertNotIn("fixture-not-for-output", out)
            self.assertEqual((target / "config.yaml").read_text(), "listen: changed")
            (target / "config.yaml").write_bytes(b"\x1b[31m")
            rc, out, err = self.invoke("--diff", "--repo", repo, "--root", self.root)
            self.assertEqual((rc, out), (2, ""))
            self.assertIn("diff requires printable UTF-8 text", err)
            (target / "config.yaml").unlink()
            rc, out, err = self.invoke("--diff", "--repo", repo, "--root", self.root)
            self.assertEqual((rc, out), (2, ""))
            self.assertIn("managed file missing or unreadable", err)

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

    def monitoring_tree(self, order):
        repo = self.root / "repo"
        for name in ("monitoring", "logging", "registry-cache"):
            source = repo / "runner/stacks" / name
            source.parent.mkdir(parents=True, exist_ok=True)
            shutil.copytree(ROOT / "runner/stacks" / name, source)
            target = self.root / "opt" / name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copytree(source, target)
        ports = {"registry-cache": 5001, "loki": 3100, "alloy": 12345}
        prom = self.root / "opt/monitoring/prometheus/prometheus.yml"
        for job in order:
            with prom.open("a") as stream:
                stream.write(f'  - job_name: {job}\n    static_configs:\n      - targets: ["127.0.0.1:{ports[job]}"]\n')
        shutil.copyfile(repo / "runner/stacks/logging/grafana-datasource.yml",
                        self.root / "opt/monitoring/grafana/provisioning/datasources/loki.yml")
        return repo

    def test_prometheus_extra_jobs_are_compared_regardless_of_installer_order(self):
        for order in (("loki", "alloy", "registry-cache"), ("alloy", "registry-cache", "loki"),
                      ("registry-cache", "loki", "alloy")):
            with self.subTest(order=order):
                self.root = Path(self.tmp.name) / "-".join(order)
                repo = self.monitoring_tree(order)
                with patch.dict(GLOBALS, {"runtime_drift": lambda *a: None}):
                    self.assertEqual(fresh.drift(repo, self.root)[0], [])

    def test_prometheus_missing_or_edited_extra_job_is_still_drift(self):
        repo = self.monitoring_tree(("loki", "registry-cache"))   # alloy was never appended
        with patch.dict(GLOBALS, {"runtime_drift": lambda *a: None}):
            findings = fresh.drift(repo, self.root)[0]
        self.assertEqual([f["item"] for f in findings], [str(self.root / "opt/monitoring/prometheus/prometheus.yml")])
        prom = self.root / "opt/monitoring/prometheus/prometheus.yml"
        prom.write_text(prom.read_text() + "  - job_name: alloy\n    static_configs:\n      - targets: [\"127.0.0.1:1\"]\n")
        with patch.dict(GLOBALS, {"runtime_drift": lambda *a: None}):
            self.assertEqual(len(fresh.drift(repo, self.root)[0]), 1)

    def test_check_update_joins_wrapped_long_package_names(self):
        text = ("kernel-core.aarch64                      6.12.0-55.el10          baseos\n"
                "a-very-long-package-name-that-dnf-wraps-onto-two-lines.noarch\n"
                "                                         2.0.1-3.el10            appstream\n"
                "\n"
                "Obsoleting Packages\n"
                "new-pkg.aarch64                          2.0-1.el10              baseos\n"
                "    old-pkg.aarch64                      1.0-1.el10              @anaconda\n")
        self.assertEqual(fresh.check_update_names(text),
                         ["a-very-long-package-name-that-dnf-wraps-onto-two-lines", "kernel-core", "new-pkg"])
        self.assertEqual(fresh.check_update_names(""), [])

    def test_reboot_state_prefers_dnf_needs_restarting_and_unknown_is_not_an_error(self):
        def which(names):
            return lambda name: f"/usr/bin/{name}" if name in names else None
        def runner(results, calls):
            def command(argv, **kwargs):
                calls.append(argv)
                outcome = results[argv[0]]
                if isinstance(outcome, Exception):
                    raise outcome
                return subprocess.CompletedProcess(argv, outcome[0], outcome[1], "")
            return command
        no_file = patch.object(GLOBALS["Path"], "exists", return_value=False)
        cases = [
            ({"dnf"}, {"dnf": (1, "Reboot is required to ensure that your system benefits")}, "required", ["dnf"]),
            ({"dnf"}, {"dnf": (0, "No core libraries or services have been updated")}, "not-required", ["dnf"]),
            ({"dnf"}, {"dnf": (1, "")}, "unknown", ["dnf"]),   # a generic DNF error is not a reboot request
            ({"dnf"}, {"dnf": fresh.CheckError("timed out")}, "unknown", ["dnf"]),
            ({"dnf", "needs-restarting"}, {"dnf": (1, "No such command"), "needs-restarting": (1, "Reboot is required")},
             "required", ["dnf", "needs-restarting"]),
            ({"needs-restarting"}, {"needs-restarting": (0, "")}, "not-required", ["needs-restarting"]),
            (set(), {}, "unknown", []),
        ]
        for present, results, want, called in cases:
            calls = []
            with self.subTest(present=present, want=want), no_file, patch("shutil.which", side_effect=which(present)), \
                 patch.dict(GLOBALS, {"run": runner(results, calls)}):
                self.assertEqual(fresh.reboot_state(), want)
                self.assertEqual([c[0] for c in calls], called)
                if "dnf" in called:
                    self.assertEqual(calls[0], ["dnf", "-q", "-C", "needs-restarting", "-r"])

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
