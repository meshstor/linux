#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
# Unit: parse_args populates globals correctly; rejects bad input.
set -e
# shellcheck source=tools/testing/selftests/perf-bench-tcp/lib.sh
. "$(dirname "$0")/lib.sh"
pbt_run_test "args"

# shellcheck source=dkms/scripts/run-perf-bench-tcp.sh
. "$PBT_SCRIPT"

# Defaults (backward-compat positional form: 2 partitions + suites = raid1)
parse_args /dev/p0 /dev/p1 /tmp/suiteA
pbt_assert_eq "${LOCALS[0]}"  "/dev/p0"          "LOCALS[0]"
pbt_assert_eq "${REMOTES[0]}" "/dev/p1"          "REMOTES[0]"
pbt_assert_eq "${#LOCALS[@]}"  "1"               "len(LOCALS) default"
pbt_assert_eq "${#REMOTES[@]}" "1"               "len(REMOTES) default"
pbt_assert_eq "$LEVEL"         "raid1"           "LEVEL default"
pbt_assert_eq "$RAID_DEVICES"  "2"               "RAID_DEVICES default"
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

# Flags (raid1 still positional)
parse_args --bitmap=internal --port=5555 --addr=10.0.0.1 \
           --out-dir=/tmp/out --fail-fast --keep \
           /dev/p0 /dev/p1 /tmp/s
pbt_assert_eq "$BITMAP"    "internal"   "BITMAP override"
pbt_assert_eq "$PORT"      "5555"       "PORT override"
pbt_assert_eq "$ADDR"      "10.0.0.1"   "ADDR override"
pbt_assert_eq "$OUT_DIR"   "/tmp/out"   "OUT_DIR override"
pbt_assert_eq "$FAIL_FAST" "1"          "FAIL_FAST set"
pbt_assert_eq "$KEEP"      "1"          "KEEP set"

# raid10 via repeated --local/--remote
parse_args --level=raid10 \
           --local=/dev/a --local=/dev/b \
           --remote=/dev/c --remote=/dev/d \
           /tmp/s
pbt_assert_eq "$LEVEL"         "raid10"  "LEVEL raid10"
pbt_assert_eq "${#LOCALS[@]}"  "2"       "raid10 LOCALS"
pbt_assert_eq "${#REMOTES[@]}" "2"       "raid10 REMOTES"
pbt_assert_eq "${LOCALS[1]}"   "/dev/b"  "LOCALS[1]"
pbt_assert_eq "${REMOTES[1]}"  "/dev/d"  "REMOTES[1]"
pbt_assert_eq "$RAID_DEVICES"  "4"       "raid10 RAID_DEVICES"
pbt_assert_eq "${SUITES[0]}"   "/tmp/s"  "raid10 SUITES[0]"

# raid10 with 6 devices (3+3)
parse_args --level=raid10 \
           --local=/dev/a --local=/dev/b --local=/dev/c \
           --remote=/dev/d --remote=/dev/e --remote=/dev/f \
           /tmp/s
pbt_assert_eq "$RAID_DEVICES"  "6"       "raid10 6-dev"

# Errors: too few positionals (positional form)
if (parse_args /dev/p0 /dev/p1) 2>/dev/null; then
    echo "FAIL: should reject 2 positionals (no suite)" >&2; exit 1
fi

# Errors: flag form with no suite
if (parse_args --local=/dev/a --remote=/dev/b) 2>/dev/null; then
    echo "FAIL: should reject flag form with no suite" >&2; exit 1
fi

# Errors: same partition twice (positional form)
if (parse_args /dev/p0 /dev/p0 /tmp/s) 2>/dev/null; then
    echo "FAIL: should reject identical partitions (positional)" >&2; exit 1
fi

# Errors: same partition in --local and --remote
if (parse_args --level=raid10 \
        --local=/dev/a --local=/dev/b \
        --remote=/dev/b --remote=/dev/c \
        /tmp/s) 2>/dev/null; then
    echo "FAIL: should reject duplicate across --local/--remote" >&2; exit 1
fi

# Errors: --local count != --remote count
if (parse_args --level=raid10 \
        --local=/dev/a --local=/dev/b \
        --remote=/dev/c \
        /tmp/s) 2>/dev/null; then
    echo "FAIL: should reject mismatched --local/--remote counts" >&2; exit 1
fi

# Errors: raid1 with 4 devices
if (parse_args --level=raid1 \
        --local=/dev/a --local=/dev/b \
        --remote=/dev/c --remote=/dev/d \
        /tmp/s) 2>/dev/null; then
    echo "FAIL: should reject raid1 with 4 devices" >&2; exit 1
fi

# Errors: raid10 with 2 devices
if (parse_args --level=raid10 \
        --local=/dev/a --remote=/dev/b \
        /tmp/s) 2>/dev/null; then
    echo "FAIL: should reject raid10 with 2 devices" >&2; exit 1
fi

# Errors: unknown level
if (parse_args --level=raid5 /dev/p0 /dev/p1 /tmp/s) 2>/dev/null; then
    echo "FAIL: should reject --level=raid5" >&2; exit 1
fi

# Errors: unknown flag
if (parse_args --bogus /dev/p0 /dev/p1 /tmp/s) 2>/dev/null; then
    echo "FAIL: should reject --bogus" >&2; exit 1
fi

echo "ok"
