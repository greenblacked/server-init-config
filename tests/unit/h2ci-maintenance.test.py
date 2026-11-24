#!/usr/bin/env python3
import fcntl
import json
import os
from pathlib import Path
import runpy
import sqlite3
import subprocess
import sys
import tempfile
import time
from types import SimpleNamespace
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
update = runpy.run_path(str(ROOT / "runner/scripts/h2ci-maintenance"))["update"]
daily = update.__globals__["daily"]
render = runpy.run_path(str(ROOT / "runner/scripts/h2ci-telegram-notify"))["daily_maintenance"]


class MaintenanceTests(unittest.TestCase):
    def test_update_outcomes(self):
        package = "Updated kernel-core.aarch64 6.12-2"
        inventory = [b"old rpm"]
        cases = [(0, None, [], inventory, inventory, "unchanged"),
                 (0, None, [], inventory, [b"new rpm"], "unverified"),
                 (0, None, [], None, None, "unverified"),
                 (0, True, [package], inventory, [b"new rpm"], "applied"),
                 (1, False, [package], inventory, [b"new rpm"], "partial"),
                 (1, None, [], inventory, inventory, "failed"),
                 (0, False, [], inventory, inventory, "unverified")]
        with tempfile.TemporaryDirectory() as directory:
            result = Path(directory) / "result"
            locks = tuple(str(Path(directory) / name) for name in ("engine", "server"))
            state = Path(directory) / "state"
            for rc, complete, packages, before, after, outcome in cases:
                with self.subTest(outcome=outcome), patch.dict(update.__globals__, {
                    "UPDATE_RESULT": result, "HEALTH_STATE": state, "LOCKS": locks, "run": lambda *_: rc,
                    "rpm_inventory": iter((before, after)).__next__,
                    "transaction": lambda _: (complete, packages), "reboot_status": lambda: "unknown",
                }):
                    self.assertEqual(update(), int(outcome not in {"unchanged", "applied"}))
                    recorded = json.loads(result.read_text())
                    self.assertEqual((recorded["update"], recorded["packages"]), (outcome, packages))
                    self.assertIn(f"outcome={outcome} reboot=unknown", state.read_text())
                    self.assertEqual(state.stat().st_mode & 0o777, 0o644)
            with open(locks[0], "a") as lock, patch.dict(update.__globals__, {
                "UPDATE_RESULT": result, "HEALTH_STATE": state, "LOCKS": locks,
                "run": lambda *_: self.fail("busy updater executed DNF"),
            }):
                fcntl.flock(lock, fcntl.LOCK_EX)
                self.assertEqual(update(), 75)
                self.assertEqual(json.loads(result.read_text())["update"], "busy")

    def test_sequence_and_stale_results(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)
            result, report, freshness, receipt = (
                path / name for name in ("result", "report", "freshness", "delivery"))
            for stale in (False, True):
                calls = []

                def run(*args):
                    calls.append(args[-1])
                    if len(calls) == 1:
                        result.write_text(json.dumps({"update": "unchanged", "packages": [],
                                                      "reboot": "not needed", "finished_ns": 9 if stale else 11}))
                    if len(calls) == 2:
                        if stale:
                            return 1
                        freshness.write_text("{}")
                    if len(calls) == 3:
                        receipt.write_text(json.dumps({"run_id": json.loads(report.read_text())["run_id"],
                                                       "message_id": 19}))
                    return 0

                with patch.dict(daily.__globals__, {"UPDATE_RESULT": result, "DAILY_REPORT": report,
                                                   "FRESH_REPORT": freshness, "DELIVERY_RECEIPT": receipt,
                                                   "run": run}):
                    with patch.object(daily.__globals__["time"], "monotonic_ns", return_value=10):
                        self.assertEqual(daily(), int(stale))
                self.assertEqual(calls, ["h2ci-server-update.service", "server-freshness.service",
                                         "h2ci-telegram-notify@daily.service"])
                recorded = json.loads(report.read_text())
                self.assertEqual(recorded["update"], "failed" if stale else "unchanged")
                self.assertEqual(recorded["freshness"], "failed" if stale else "refreshed")

    def test_start_success_without_current_receipt_is_not_delivery(self):
        deliver = update.__globals__["deliver"]
        with tempfile.TemporaryDirectory() as directory:
            report = Path(directory) / "report"
            receipt = Path(directory) / "delivery"
            with patch.dict(deliver.__globals__, {
                "DAILY_REPORT": report, "DELIVERY_RECEIPT": receipt, "run": lambda *_: 0,
            }):
                self.assertFalse(deliver({}))
                old_id = json.loads(report.read_text())["run_id"]
                receipt.write_text(json.dumps({"run_id": old_id, "message_id": 19}))
                self.assertFalse(deliver({}))

    def test_health_uses_managed_status_and_marks_stale_reboot_unknown(self):
        with tempfile.TemporaryDirectory() as directory:
            state = Path(directory) / "state"
            legacy = Path(directory) / "legacy"
            legacy.mkdir()
            (legacy / "state").write_text("time=1 updates=999 reboot=1 updated=1 uresult=ok\n")
            for age, expected in ((10, "unchanged (0 package changes recorded); reboot: not needed"),
                                  (140000, "stale (last managed update")):
                state.write_text(f"time={int(time.time()) - age} outcome=unchanged reboot=not-needed changes=0\n")
                output = subprocess.check_output(
                    ["bash", str(ROOT / "common/health"), "--brief", "--no-color"], text=True,
                    env={**os.environ, "HEALTH_REEXEC": "1", "H2CI_UPDATE_STATUS_FILE": str(state),
                         "SERVER_UPDATE_STATE": str(legacy)},
                    timeout=10,
                )
                self.assertIn(expected, output)
                self.assertNotIn("999 update(s) pending", output)
                if age > 129600:
                    self.assertIn("reboot: unknown", output)

    def test_dnf_history_uses_only_tagged_completed_items(self):
        query = update.__globals__["transaction"]
        with tempfile.TemporaryDirectory() as directory:
            db = Path(directory) / "history.sqlite"
            with sqlite3.connect(db) as connection:
                connection.executescript("""
                    CREATE TABLE trans(id, state, comment);
                    CREATE TABLE trans_item(trans_id, item_id, action, state);
                    CREATE TABLE rpm(item_id, name, epoch, version, release, arch);
                    INSERT INTO trans VALUES (1, 1, 'wanted'), (2, 1, 'unrelated');
                    INSERT INTO trans_item VALUES (1, 1, 6, 1), (1, 2, 7, 1),
                        (1, 3, 1, 2), (2, 3, 1, 1);
                    INSERT INTO rpm VALUES (1, 'example', 2, '3', '4', 'aarch64'),
                        (2, 'example', 2, '2', '4', 'aarch64'), (3, 'other', 0, '1', '1', 'noarch');
                """)
            try:
                import libdnf
            except ImportError:
                enums = SimpleNamespace(
                    TransactionItemAction_INSTALL=1, TransactionItemAction_DOWNGRADE=2,
                    TransactionItemAction_OBSOLETE=4, TransactionItemAction_OBSOLETED=5,
                    TransactionItemAction_UPGRADE=6, TransactionItemAction_REMOVE=8,
                    TransactionItemAction_REINSTALL=9, TransactionItemState_DONE=1,
                    TransactionState_DONE=1,
                )
                libdnf = SimpleNamespace(transaction=enums)
            with patch.dict(sys.modules, {"libdnf": libdnf}):
                self.assertEqual(query("wanted", db), (True, ["Updated example.aarch64 2:3-4"]))
                self.assertEqual(query("missing", db), (None, []))

    def test_reboot_probe_distinguishes_generic_failure(self):
        probe = update.__globals__["reboot_status"]
        for rc, output, expected in ((1, "Reboot is required", "required"),
                                     (0, "Reboot should not be necessary.", "not needed"),
                                     (1, "", "unknown"), (0, "", "unknown")):
            with patch.object(subprocess, "run", return_value=subprocess.CompletedProcess([], rc, output, "")):
                self.assertEqual(probe(), expected)

    def test_missing_runtime_directory_is_a_message_not_a_traceback(self):
        main = update.__globals__["main"]
        with tempfile.TemporaryDirectory() as directory:
            missing = Path(directory) / "run" / "x"
            for command, name, unit in (("update", "UPDATE_RESULT", "h2ci-server-update.service"),
                                        ("daily", "DAILY_REPORT", "h2ci-daily-maintenance.service"),
                                        ("test", "DAILY_REPORT", "h2ci-daily-maintenance.service")):
                calls = []
                with self.subTest(command=command), patch.object(os, "geteuid", return_value=0), \
                     patch.object(sys, "argv", ["h2ci-maintenance", command]), \
                     patch.dict(main.__globals__, {name: missing / "file.json", "update": lambda: calls.append("update"),
                                                   "daily": lambda test=False: calls.append("daily")}), \
                     patch("sys.stderr") as stderr:
                    self.assertEqual(main(), 2)
                text = "".join(call.args[0] for call in stderr.write.call_args_list)
                self.assertIn(f"systemctl start {unit}", text)
                self.assertEqual(calls, [])
            (Path(directory) / "run" / "x").mkdir(parents=True)
            with patch.object(os, "geteuid", return_value=0), patch.object(sys, "argv", ["h2ci-maintenance", "update"]), \
                 patch.dict(main.__globals__, {"UPDATE_RESULT": missing / "file.json", "update": lambda: 0}):
                self.assertEqual(main(), 0)

    def test_telegram_summary(self):
        lines, actions = render({"update": "unchanged", "reboot": "not needed", "freshness": "refreshed"})
        self.assertEqual(actions, [])
        self.assertIn("Updates: none · Reboot: not needed · Freshness: refreshed", lines)
        lines, actions = render({"update": "partial", "packages": ["example"] * 9, "reboot": "unknown"})
        self.assertIn("- +3 more (see DNF history)", lines)
        self.assertIn("Reboot: unknown", lines)
        self.assertEqual(len(actions), 3)


if __name__ == "__main__":
    unittest.main()
