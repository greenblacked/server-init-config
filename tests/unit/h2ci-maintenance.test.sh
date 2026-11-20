#!/usr/bin/env bash

test_h2ci_daily_maintenance() {
  python3 "$REPO/tests/unit/h2ci-maintenance.test.py"
}
