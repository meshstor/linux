#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
#
# RCA #5 evidence probe: does legacy_async_del_gendisk=Y cause member
# events-counter divergence across `mdadm --stop`?
#
# Runs N trials in each mode. Per trial: create a 2-member raid1 with
# bitmap=internal, write churn that flips many bitmap regions, --stop,
# then read the events counter on both members. Output is a JSON
# summary suitable for piping to jq or inspecting by hand.
#
# Exit code is always 0 (this is a probe, not a pass/fail test). The
# caller decides whether the deltas support shipping D4
# (legacy_async_del_gendisk default flip).
#
# Decision rule (consumed by the cover letter for D4):
#   D4 is justified iff max(delta_N) == 0 AND max(delta_Y) >= 2
#   across >= 20 trials.

set -eu

DIR="$(dirname "$0")"

# Use a build-dir-anchored TMPDIR so 100M backing files land in the
# harness build tree (which has dedicated space) instead of filling
# /tmp. This must be set BEFORE sourcing lib.sh so llbitmap_make_loop
# picks it up via the ${TMPDIR:-/tmp} default.
DEFAULT_TMPDIR="$(git -C "$DIR" rev-parse --show-toplevel 2>/dev/null)/build/llbitmap-tmp"
export TMPDIR="${TMPDIR:-$DEFAULT_TMPDIR}"
mkdir -p "$TMPDIR"

. "$DIR/lib.sh"

llbitmap_require_root
llbitmap_require_modules
llbitmap_require_tools

if ! command -v fio >/dev/null 2>&1; then
	echo "SKIP: fio not installed" >&2
	exit 4
fi

PARAM=/sys/module/ms_mod/parameters/legacy_async_del_gendisk
if [ ! -w "$PARAM" ]; then
	echo "SKIP: $PARAM not writable" >&2
	exit 4
fi

ORIG_MODE=$(cat "$PARAM")
TRIALS=${TRIALS:-20}
CHURN_RUNTIME=${CHURN_RUNTIME:-2}

restore_mode() {
	echo "$ORIG_MODE" > "$PARAM" 2>/dev/null || true
}
trap 'restore_mode; llbitmap_cleanup' EXIT

run_trial() {
	# Caller has already set the param. We just do create -> churn ->
	# stop -> read events. Echos two integers and a delta on one line.
	local la lb e_a e_b
	la=$(llbitmap_make_loop 100)
	lb=$(llbitmap_make_loop 100)
	llbitmap_alloc_ms_dev >/dev/null
	local ms_dev="$LLBITMAP_TEST_MS_DEV"

	"$MDADM" --create "$ms_dev" \
		--level=1 --metadata=1.2 --raid-devices=2 --homehost=any \
		--bitmap=internal "$la" "$lb" --run --force >/dev/null 2>&1

	fio --name=churn --filename="$ms_dev" --bs=4k --rw=randwrite \
		--runtime="$CHURN_RUNTIME" --time_based --direct=1 \
		--iodepth=8 --ioengine=libaio --size=50M --norandommap \
		--output=/dev/null >/dev/null 2>&1 || true

	"$MDADM" --wait "$ms_dev" >/dev/null 2>&1 || true
	"$MDADM" --stop "$ms_dev" >/dev/null 2>&1

	e_a=$(llbitmap_events_of "$la")
	e_b=$(llbitmap_events_of "$lb")
	echo "$e_a $e_b $((e_a > e_b ? e_a - e_b : e_b - e_a))"

	# Mid-test cleanup so we don't accumulate 40+ loop devices and
	# 100M backing files per trial over a full run. NB: lib.sh's
	# LLBITMAP_TEST_FILES tracking happens inside llbitmap_make_loop
	# which we call via $(...) - the array updates land in a subshell
	# and never reach the parent. So we scan the dedicated TMPDIR
	# directly. Safe because TMPDIR is harness-owned (build/...).
	"$MDADM" --stop "$ms_dev" >/dev/null 2>&1 || true
	losetup -d "$la" >/dev/null 2>&1 || true
	losetup -d "$lb" >/dev/null 2>&1 || true
	rm -f "$TMPDIR"/llbitmap-selftest.*.img
	LLBITMAP_TEST_LOOPS=()
	LLBITMAP_TEST_FILES=()
	LLBITMAP_TEST_MS_DEV=""
}

declare -A MAX
declare -A SUM

for mode in Y N; do
	echo "$mode" > "$PARAM"
	cat "$PARAM"  # sanity echo to stderr
	MAX[$mode]=0
	SUM[$mode]=0
	for i in $(seq 1 "$TRIALS"); do
		read -r eA eB d < <(run_trial)
		[ "$d" -gt "${MAX[$mode]}" ] && MAX[$mode]=$d
		SUM[$mode]=$(( SUM[$mode] + d ))
		echo "TRIAL mode=$mode i=$i eA=$eA eB=$eB delta=$d" >&2
	done
done

# Emit JSON summary on stdout.
printf '{\n'
printf '  "trials": %d,\n' "$TRIALS"
printf '  "churn_runtime_s": %d,\n' "$CHURN_RUNTIME"
printf '  "Y": { "delta_max": %d, "delta_mean": "%.2f" },\n' \
	"${MAX[Y]}" "$(awk "BEGIN{print ${SUM[Y]}/$TRIALS}")"
printf '  "N": { "delta_max": %d, "delta_mean": "%.2f" }\n' \
	"${MAX[N]}" "$(awk "BEGIN{print ${SUM[N]}/$TRIALS}")"
printf '}\n'

# Always exit 0; this is a probe.
exit 0
