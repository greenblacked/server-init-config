# shellcheck shell=bash
# Python tests use only temporary directories and mocked subprocess/network responses.
test_freshness_checks() {
  PYTHONDONTWRITEBYTECODE=1 python3 "$REPO/tests/unit/freshness_checks.py"
}
