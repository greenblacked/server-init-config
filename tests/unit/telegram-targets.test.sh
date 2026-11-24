# shellcheck shell=bash

test_telegram_prometheus_targets() {
  PYTHONDONTWRITEBYTECODE=1 python3 - "$REPO/runner/scripts/h2ci-telegram-notify" <<'PY_TEST'
from datetime import datetime
import json
import runpy
import sys
from unittest.mock import patch

m = runpy.run_path(sys.argv[1])
now = datetime.now().timestamp()

def row(job, port, *samples):
    return {"metric": {"job": job, "instance": f"127.0.0.1:{port}"},
            "values": [(now - age, value) for age, value in samples]}

rows = [row("prometheus", 9090, (3, "1")), row("node", 9100, (61, "1")),
        row("gitlab-runner", 9252, (40, "0"), (25, "0"), (10, "0")),
        row("loki", 3100, (45, "0"), (30, "1"), (15, "0")),
        row("alloy", 12345, (20, "NaN")), row("registry-cache", 5000, (1, "1"))]
assert m["classify_prometheus_targets"](rows, now) == {
    "prometheus": "healthy", "node": "stale", "gitlab-runner": "down",
    "loki": "transient", "alloy": "invalid", "registry-cache": "missing",
}
assert m["scrape_state"]([(now - 15, "0"), (now - 1, "1")], now) == "healthy"
assert m["scrape_state"]([(now - 90, "0"), (now - 75, "0"), (now - 1, "0")], now) == "transient"
assert m["scrape_state"]([(now + 10, "1")], now) == "invalid"
assert m["classify_prometheus_targets"]([rows[0], rows[0]], now)["prometheus"] == "invalid"
with patch("http.client.HTTPConnection") as connect:
    response = connect.return_value.getresponse.return_value
    response.status = 200
    response.read.return_value = json.dumps({"status": "success", "data": {"resultType": "matrix", "result": rows}}).encode()
    summary, actions = m["prometheus_health"]()
    assert summary.startswith("Prometheus targets: 1/6 healthy") and "recent scrape failures" in summary
    assert all(any(name in action for action in actions) for name in ("node", "gitlab-runner", "alloy", "registry-cache"))
    assert not any("loki" in action for action in actions)
    connect.return_value.request.side_effect = TimeoutError
    summary, actions = m["prometheus_health"]()
    assert summary == "Prometheus targets: unavailable" and actions
PY_TEST
}


test_telegram_host_anomalies() {
  PYTHONDONTWRITEBYTECODE=1 python3 - "$REPO/runner/scripts/h2ci-telegram-notify" <<'PY_TEST'
import json
import runpy
import sys
from unittest.mock import patch

m = runpy.run_path(sys.argv[1])

def row(signal, value):
    return {"metric": {"signal": signal}, "value": [0, str(value)]}

healthy = [row("readonly", 0), row("inode_free_max_ratio", 0.96), row("oom_24h", 0)]
assert m["host_anomaly_actions"](healthy) == []
assert m["host_anomaly_actions"]([healthy[0], row("inode_free_max_ratio", 0.10), healthy[2]]) == []
issues = m["host_anomaly_actions"]([row("readonly", 1), row("inode_free_max_ratio", .08), row("oom_24h", 1.03)])
assert len(issues) == 3
assert "read-only root" in issues[0] and "under 10%" in issues[1] and "about 1 host OOM" in issues[2]
missing = m["host_anomaly_actions"]([row("readonly", 0), row("readonly", 1), row("inode_free_max_ratio", "NaN")])
assert len(missing) == 3 and not any("read-only root" in action for action in missing)
query = m["host_anomaly_query"]()
assert "[15m]" in query and ">= 45" in query and "[24h]" in query and ">= 5184" in query
with patch("http.client.HTTPConnection") as connect:
    response = connect.return_value.getresponse.return_value
    response.status = 200
    response.read.return_value = json.dumps({"status": "success", "data": {"resultType": "vector", "result": healthy}}).encode()
    assert m["host_anomalies"]() == []
    connect.return_value.request.side_effect = TimeoutError
    assert m["host_anomalies"]() == ["Check host monitoring (storage and OOM metrics unavailable)"]
PY_TEST
}

test_telegram_credentials_file_must_be_root_owned_0600() {
  PYTHONDONTWRITEBYTECODE=1 python3 - "$REPO/runner/scripts/h2ci-telegram-notify" <<'PY_TEST'
import os
from pathlib import Path
import runpy
import sys
import tempfile

m = runpy.run_path(sys.argv[1])
load = m["load_credentials"]
me = os.getuid()
with tempfile.TemporaryDirectory() as directory:
    path = Path(directory) / "telegram.credentials"
    assert load(path, me)[1] == "missing"
    path.write_text("123:abc\n42\n")
    for mode in (0o644, 0o640, 0o660, 0o400, 0o700):
        path.chmod(mode)
        text, kind, message = load(path, me)
        assert text is None and kind == "unsafe" and "0600" in message and f"{mode:04o}" in message, (mode, message)
    path.chmod(0o600)
    assert load(path, me) == ("123:abc\n42\n", None, None)
    assert load(path, me + 1)[1] == "unsafe"   # owner is not the expected one (root on a host)
    link = Path(directory) / "link"
    link.symlink_to(path)
    assert load(link, me)[1] == "unsafe"      # a symlink is refused, not followed
    assert load(Path(directory), me)[1] == "unsafe"
PY_TEST
}

test_telegram_missing_or_unsafe_credentials_are_reported_not_silent() {
  PYTHONDONTWRITEBYTECODE=1 python3 - "$REPO/runner/scripts/h2ci-telegram-notify" <<'PY_TEST'
import contextlib
import io
import os
from pathlib import Path
import runpy
import sys
import tempfile
from unittest.mock import patch

m = runpy.run_path(sys.argv[1])
main = m["main"]
real_load = m["load_credentials"]

def run(event, path):
    err = io.StringIO()
    with tempfile.TemporaryDirectory() as stamps, \
         patch.dict(main.__globals__, {"load_credentials": lambda: real_load(path, os.getuid()), "STAMP_DIR": Path(stamps)}), \
         patch.object(sys, "argv", ["h2ci-telegram-notify", event]), \
         patch.dict(os.environ, {"JOURNAL_STREAM": "1:2"}), contextlib.redirect_stderr(err):
        return main(), err.getvalue()

with tempfile.TemporaryDirectory() as directory:
    path = Path(directory) / "telegram.credentials"
    rc, err = run("test", path)
    assert rc == 0 and err.startswith("<4>") and "does not exist" in err and err.count("\n") == 1, (rc, err)
    rc, err = run("daily", path)
    assert rc == 1 and "does not exist" in err, (rc, err)
    path.write_text("123:abc\n42\n")
    path.chmod(0o644)
    for event in ("test", "daily"):
        rc, err = run(event, path)
        assert rc == 78 and err.startswith("<3>") and "mode 0600" in err and "0644" in err, (rc, err)
        assert "123:abc" not in err
PY_TEST
}

test_telegram_repeating_alerts_are_rate_limited_per_event() {
  PYTHONDONTWRITEBYTECODE=1 python3 - "$REPO/runner/scripts/h2ci-telegram-notify" <<'PY_TEST'
import os
from pathlib import Path
import runpy
import sys
import tempfile
import time

m = runpy.run_path(sys.argv[1])
limited, mark = m["rate_limited"], m["mark_sent"]
window = m["RATE_LIMIT_SECONDS"]
assert window == 6 * 3600
with tempfile.TemporaryDirectory() as directory:
    stamps = Path(directory) / "stamps"          # created on first use
    now = time.time()
    assert not limited("disk-threshold", now, stamps)
    mark("disk-threshold", stamps)
    assert stamps.stat().st_mode & 0o777 == 0o700
    assert limited("disk-threshold", now + 60, stamps)
    assert not limited("server-freshness", now + 60, stamps), "per event"
    assert not limited("disk-threshold", now + window + 60, stamps), "window over"
    assert not limited("disk-threshold", now - 3600, stamps), "a stamp from the future is ignored"
    for event in ("test", "daily"):
        mark(event, stamps)
        assert not limited(event, now + 1, stamps), event
        assert not (stamps / f"{event}.stamp").exists()
    os.utime(stamps / "disk-threshold.stamp", (now - window - 5, now - window - 5))
    assert not limited("disk-threshold", now, stamps)
    mark("disk-threshold", Path(directory) / "file" / "nested")   # an unusable directory never raises
PY_TEST
}

test_telegram_send_retries_once_on_network_error_429_and_5xx() {
  PYTHONDONTWRITEBYTECODE=1 python3 - "$REPO/runner/scripts/h2ci-telegram-notify" <<'PY_TEST'
import json
import runpy
import sys
from unittest.mock import MagicMock, patch

m = runpy.run_path(sys.argv[1])
send = m["send_message"]
OK = json.dumps({"ok": True, "result": {"message_id": 5, "chat": {"id": 42}}}).encode()

def response(status, body=b"{}", retry_after=None):
    r = MagicMock(status=status)
    r.read.return_value = body
    r.getheader.return_value = retry_after
    return r

def attempt(*outcomes):
    waits = []
    conn = MagicMock()
    conn.getresponse.side_effect = outcomes
    with patch("http.client.HTTPSConnection", return_value=conn) as factory:
        result = send("123:secret", "42", "hello", sleep=waits.append)
    return result, waits, factory.call_count

(status, data), waits, calls = attempt(response(200, OK))
assert (status, data["ok"], waits, calls) == (200, True, [], 1)
(status, data), waits, calls = attempt(OSError("boom"), response(200, OK))
assert (status, calls, waits) == (200, 2, [m["RETRY_DELAY"]])
(status, data), waits, calls = attempt(response(502), response(200, OK))
assert (status, calls) == (200, 2)
(status, data), waits, calls = attempt(response(429, b'{"ok":false}', "3"), response(200, OK))
assert (status, calls, waits) == (200, 2, [3]), "Retry-After header is respected"
(status, data), waits, calls = attempt(response(429, json.dumps({"parameters": {"retry_after": 4}}).encode()), response(200, OK))
assert waits == [4], "retry_after from the Telegram body is respected"
(status, data), waits, calls = attempt(response(429, b"{}", "600"), response(200, OK))
assert waits == [m["RETRY_DELAY_MAX"]], "a long Retry-After is capped"
(status, data), waits, calls = attempt(response(429, b'{"parameters": {"retry_after": Infinity}}'), response(200, OK))
assert (status, calls, waits) == (200, 2, [m["RETRY_DELAY"]]), waits   # JSON Infinity: no OverflowError, default wait
for bad in ("inf", "nan", "-5", "", None):
    assert 0 <= m["retry_delay"](bad) <= m["RETRY_DELAY_MAX"], bad
assert m["retry_delay"](float("inf")) == m["RETRY_DELAY"]
(status, data), waits, calls = attempt(response(503), response(500))
assert (status, calls) == (500, 2), "only one retry"
(status, data), waits, calls = attempt(OSError("a"), OSError("b"))
assert (status, data, calls) == (None, None, 2)
(status, data), waits, calls = attempt(response(400), response(200, OK))
assert (status, calls, waits) == (400, 1, []), "a rejected request is not repeated"
PY_TEST
}

test_telegram_token_is_not_put_in_the_environment_and_children_get_a_minimal_one() {
  PYTHONDONTWRITEBYTECODE=1 python3 - "$REPO/runner/scripts/h2ci-telegram-notify" <<'PY_TEST'
import io
import json
import os
from pathlib import Path
import runpy
import sys
import tempfile
from unittest.mock import patch, MagicMock

path_to_script = sys.argv[1]
m = runpy.run_path(path_to_script)
main, real_load = m["main"], m["load_credentials"]
token = "123456:SECRET-token_value"
sent = []

def fake_send(tok, chat, text, **kw):
    sent.append((tok, chat, text))
    return 200, {"ok": True, "result": {"message_id": 9, "chat": {"id": 42}}}

with tempfile.TemporaryDirectory() as directory:
    cred = Path(directory) / "c"
    cred.write_text(f"{token}\n42\n"); cred.chmod(0o600)
    out = io.StringIO()
    with patch.dict(main.__globals__, {"load_credentials": lambda: real_load(cred, os.getuid()), "send_message": fake_send,
                                       "STAMP_DIR": Path(directory) / "s"}), \
         patch.object(sys, "argv", ["x", "disk-threshold"]), patch("sys.stdout", out):
        assert main() == 0
        assert "TELEGRAM_BOT_TOKEN" not in os.environ
        assert not any(token in v for v in os.environ.values())
    assert sent[0][0] == token and sent[0][2].startswith("[h2ci] ")
    assert token not in out.getvalue()
    # delivered once: the second identical alert inside the window is suppressed
    with patch.dict(main.__globals__, {"load_credentials": lambda: real_load(cred, os.getuid()), "send_message": fake_send,
                                       "STAMP_DIR": Path(directory) / "s"}), \
         patch.object(sys, "argv", ["x", "disk-threshold"]), patch("sys.stdout", io.StringIO()) as quiet:
        assert main() == 0 and len(sent) == 1 and "suppressed" in quiet.getvalue()

assert m["CHILD_ENV"] == {"PATH": "/usr/local/bin:/usr/bin:/bin", "LC_ALL": "C"}
with patch("subprocess.run", return_value=MagicMock(stdout="x\n")) as run:
    m["read_status"]("/usr/bin/df")
    m["ci_outcomes_24h"]()
assert run.call_count == 2 and all(call.kwargs["env"] == m["CHILD_ENV"] for call in run.call_args_list)
assert "os.environ[" not in Path(path_to_script).read_text().replace('os.environ["CREDENTIALS_DIRECTORY"]', '')
PY_TEST
}
