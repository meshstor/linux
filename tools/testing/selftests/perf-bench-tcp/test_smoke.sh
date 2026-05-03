#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
# Smoke: lib.sh helpers and PATH-stubs are functional.
set -e
# shellcheck source=tools/testing/selftests/perf-bench-tcp/lib.sh
. "$(dirname "$0")/lib.sh"
pbt_run_test "smoke"

pbt_stub fakecmd 0 "hello"
out="$(fakecmd arg1 arg2)"
pbt_assert_eq "$out" "hello" "stub stdout"

log="$(pbt_stub_log)"
pbt_assert_contains "$log" "STUB fakecmd arg1 arg2" "stub argv log"

pbt_stub failcmd 7
if failcmd; then
    echo "FAIL: failcmd should have exited non-zero" >&2
    exit 1
fi
echo "ok"
