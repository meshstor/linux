#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
# Unit tests for bin/perf-bench-tcp CPU governor pinning. Sourced-lib style:
# no root, no hardware, no array. perf-bench-tcp is sourceable (its main only
# runs under the BASH_SOURCE==$0 guard), so we source it and exercise the pure
# pin_governor/restore_governor helpers against a fake cpufreq tree.
set -u
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

TOOL="$REPO_ROOT/bin/perf-bench-tcp"
[ -f "$TOOL" ] || dkms_skip "tool not present: $TOOL"

# shellcheck disable=SC1090
. "$TOOL"   # sourced, not executed (guard keeps main from running)

assert_eq "function" "$(type -t pin_governor)"     "pin_governor defined"
assert_eq "function" "$(type -t restore_governor)" "restore_governor defined"

# --- pin/restore against a fake per-cpu cpufreq tree ---
cpubase="$(dkms_mktemp_dir)/cpu"
mkdir -p "$cpubase/cpu0/cpufreq" "$cpubase/cpu1/cpufreq"
echo powersave > "$cpubase/cpu0/cpufreq/scaling_governor"
echo schedutil > "$cpubase/cpu1/cpufreq/scaling_governor"   # heterogeneous on purpose
export PBT_CPU_BASE="$cpubase"

pin_governor
assert_eq "performance" "$(cat "$cpubase/cpu0/cpufreq/scaling_governor")" "cpu0 pinned to performance"
assert_eq "performance" "$(cat "$cpubase/cpu1/cpufreq/scaling_governor")" "cpu1 pinned to performance"
assert_eq "1" "$GOV_PINNED" "GOV_PINNED set after pin"
assert_eq "powersave" "$ORIG_GOVERNOR" "first cpu's original governor recorded"

restore_governor
# Each CPU restored to ITS OWN prior governor (not a single global value).
assert_eq "powersave" "$(cat "$cpubase/cpu0/cpufreq/scaling_governor")" "cpu0 restored to powersave"
assert_eq "schedutil" "$(cat "$cpubase/cpu1/cpufreq/scaling_governor")" "cpu1 restored to schedutil"
assert_eq "0" "$GOV_PINNED" "GOV_PINNED cleared after restore"

# Idempotent: a second restore (e.g. trap after manual restore) is a no-op.
restore_governor
assert_eq "powersave" "$(cat "$cpubase/cpu0/cpufreq/scaling_governor")" "cpu0 unchanged after 2nd restore"
unset PBT_CPU_BASE

# --- pin is a graceful no-op when there is no cpufreq tree (e.g. in a VM) ---
emptybase="$(dkms_mktemp_dir)/nocpufreq"
mkdir -p "$emptybase"
export PBT_CPU_BASE="$emptybase"
pin_governor
assert_eq "0" "$GOV_PINNED" "GOV_PINNED stays 0 when no scaling_governor present"
restore_governor   # must not error
unset PBT_CPU_BASE

# --- --no-pin flag (parse_args resets PIN_GOV each call) ---
parse_args /dev/x /dev/y /tmp/suite
assert_eq "1" "$PIN_GOV" "PIN_GOV defaults to 1"
parse_args --no-pin /dev/x /dev/y /tmp/suite
assert_eq "0" "$PIN_GOV" "--no-pin sets PIN_GOV=0"

dkms_pass "perf-bench-tcp governor pinning"
