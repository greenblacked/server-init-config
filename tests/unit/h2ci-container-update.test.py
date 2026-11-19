#!/usr/bin/env python3
import json
from pathlib import Path
import runpy
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
rollout = runpy.run_path(str(ROOT / "runner/scripts/h2ci-container-update"))["rollout"]
G = rollout.__globals__
PINS = json.loads((ROOT / "runner/config/h2ci-container-images.json").read_text())


class ContainerUpdateTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.base = Path(temp.name)
        context = patch.dict(G, {"COMPOSE_ROOT": self.base, "ROLLBACK_STATE": self.base, "BACKUP_ROOT": self.base})
        context.start()
        self.addCleanup(context.stop)

    def compose(self, name, image):
        project = self.base / G["SERVICES"][name][0]
        project.mkdir(exist_ok=True)
        path = project / "docker-compose.yml"
        path.write_text(f"services:\n  {name}:\n    image: {image}\n    restart: unless-stopped\n  dependency:\n    image: another/image:1\n")
        return path

    def fake_run(self, image, repos, calls):
        def run(*args):
            calls.append(args)
            if "ps" in args:
                return "cid"
            if "{{json .RepoDigests}}" in args:
                return json.dumps(repos)
            if "--format" in args:
                return f"sha256:current\n{image}\ntrue\n[]"
            self.fail(f"unexpected command: {args}")
        return run

    def test_current_digest_does_not_pull_or_recreate(self):
        calls = []
        digest = PINS["alloy"]["image"].split("@")[1]
        self.compose("alloy", "grafana/alloy:v1.19.2")
        with patch.dict(G, {"run": self.fake_run("grafana/alloy:v1.19.2", [f"grafana/alloy@{digest}"], calls)}):
            self.assertEqual(rollout("alloy", PINS["alloy"], True), "current")
            self.assertEqual(rollout("alloy", PINS["alloy"], False), "current")
        self.assertEqual(len(calls), 6)

    def test_unapproved_and_preview_never_mutate(self):
        for name, image, status in (("alloy", "grafana/alloy:v1.19.2", "deferred"),
                                    ("grafana", "grafana/grafana:12.0.0", "pending")):
            calls = []
            self.compose(name, image)
            with patch.dict(G, {"run": self.fake_run(image, [], calls)}):
                self.assertEqual(rollout(name, PINS[name], True), status)
            self.assertEqual(len(calls), 3)

    def test_reconcile_reports_rollback_as_distinct_failure(self):
        def outcome(name, *_):
            if name == "grafana":
                raise G["RolledBack"]()
            if name == "registry":
                raise RuntimeError()
            return "current"
        with patch.dict(G, {"rollout": outcome}):
            states = G["reconcile"](PINS, False)
        self.assertEqual((states["grafana"], states["registry"], states["prometheus"]),
                         ("rolled-back", "failed", "current"))

    def test_failed_readiness_restores_original_and_holds_pin(self):
        pin = dict(PINS["node-exporter"], **{"from": "prom/node-exporter:v1.8.0"})
        path = self.compose("node-exporter", pin["from"])
        original = path.read_bytes()
        calls = []

        def run(*args):
            calls.append(args)
            if "ps" in args:
                return "" if "--filter" in args else "cid"
            if "{{json .RepoDigests}}" in args:
                return "[]"
            if "--format" in args:
                if "{{.Config.Image}}" in args[args.index("--format") + 1]:
                    return f"old-id\n{pin['from']}\ntrue\n[]"
                return "new-id" if args[-1] == pin["image"] else "old-id"
            return ""

        def state(*_):
            if path.read_bytes() != original:
                raise RuntimeError("candidate not ready")
            return True

        with patch.dict(G, {"run": run, "state": state}), patch.object(G["time"], "sleep"):
            with self.assertRaises(G["RolledBack"]):
                rollout("node-exporter", pin, False)
            self.assertEqual(path.read_bytes(), original)
            self.assertEqual(sum("up" in call for call in calls), 2)
            self.assertEqual(rollout("node-exporter", pin, False), "rolled-back")
            self.assertEqual(sum("up" in call for call in calls), 2)


if __name__ == "__main__":
    unittest.main()
