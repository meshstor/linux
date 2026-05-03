#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
# Unit: parse_args populates globals correctly; rejects bad input.
set -e
# shellcheck source=tools/testing/selftests/perf-bench-tcp/lib.sh
. "$(dirname "$0")/lib.sh"
pbt_run_test "args"

# shellcheck source=dkms/scripts/run-perf-bench-tcp.sh
. "$PBT_SCRIPT"

# Defaults
parse_args /dev/p0 /dev/p1 /tmp/suiteA
pbt_assert_eq "$PART_LOCAL"   "/dev/p0"          "PART_LOCAL"
pbt_assert_eq "$PART_REMOTE"  "/dev/p1"          "PART_REMOTE"
pbt_assert_eq "${SUITES[0]}"  "/tmp/suiteA"      "SUITES[0]"
pbt_assert_eq "${#SUITES[@]}" "1"                "len(SUITES)"
pbt_assert_eq "$BITMAP"       "lockless"         "BITMAP default"
pbt_assert_eq "$PORT"         "4420"             "PORT default"
pbt_assert_eq "$ADDR"         "127.0.0.1"        "ADDR default"
pbt_assert_eq "$FAIL_FAST"    "0"                "FAIL_FAST default"
pbt_assert_eq "$KEEP"         "0"                "KEEP default"

# Multi-suite
parse_args /dev/p0 /dev/p1 /tmp/s1 /tmp/s2 /tmp/s3
pbt_assert_eq "${#SUITES[@]}" "3"                "len(SUITES) multi"
pbt_assert_eq "${SUITES[2]}"  "/tmp/s3"          "SUITES[2]"

# Flags
parse_args --bitmap=internal --port=5555 --addr=10.0.0.1 \
           --out-dir=/tmp/out --fail-fast --keep \
           /dev/p0 /dev/p1 /tmp/s
pbt_assert_eq "$BITMAP"    "internal"   "BITMAP override"
pbt_assert_eq "$PORT"      "5555"       "PORT override"
pbt_assert_eq "$ADDR"      "10.0.0.1"   "ADDR override"
pbt_assert_eq "$OUT_DIR"   "/tmp/out"   "OUT_DIR override"
pbt_assert_eq "$FAIL_FAST" "1"          "FAIL_FAST set"
pbt_assert_eq "$KEEP"      "1"          "KEEP set"

# Errors: too few positionals
if (parse_args /dev/p0 /dev/p1) 2>/dev/null; then
    echo "FAIL: should reject 2 positionals (no suite)" >&2; exit 1
fi

# Errors: same partition twice
if (parse_args /dev/p0 /dev/p0 /tmp/s) 2>/dev/null; then
    echo "FAIL: should reject identical partitions" >&2; exit 1
fi

# Errors: unknown flag
if (parse_args --bogus /dev/p0 /dev/p1 /tmp/s) 2>/dev/null; then
    echo "FAIL: should reject --bogus" >&2; exit 1
fi

echo "ok"
