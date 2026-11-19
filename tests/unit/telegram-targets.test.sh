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
