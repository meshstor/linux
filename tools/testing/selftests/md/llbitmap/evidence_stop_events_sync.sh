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
# This is an evidence probe, NOT a pass/fail regression test: it measures and
# emits JSON, it asserts no code-path correctness. It is deliberately named
# evidence_*.sh (not test_*.sh) and kept out of TEST_PROGS so the selftest
# harness does not run it and bank a meaningless verdict; run it by hand when
# gathering D4 evidence. Exit code is always 0 (a probe). The caller decides
# whether the deltas support shipping D4 (legacy_async_del_gendisk default flip)
# from the JSON summary.
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

PARAM=/sys/module/${LLBITMAP_CORE_MOD}/parameters/legacy_async_del_gendisk
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
	local la lb fa fb e_a e_b
	# Call make_loop WITHOUT command substitution so its
	# LLBITMAP_TEST_LOOPS/FILES bookkeeping survives into this function
	# (the same pattern llbitmap_alloc_ms_dev relies on). This lets the
	# teardown below delete exactly the two backing files this trial
	# created, instead of a broad glob that races a concurrent trial.
	llbitmap_make_loop 100 >/dev/null
	la="${LLBITMAP_TEST_LOOPS[-1]}"; fa="${LLBITMAP_TEST_FILES[-1]}"
	llbitmap_make_loop 100 >/dev/null
	lb="${LLBITMAP_TEST_LOOPS[-1]}"; fb="${LLBITMAP_TEST_FILES[-1]}"
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
	# 100M backing files per trial over a full run. Detach the two
	# loops and remove exactly the two backing files this trial created
	# (captured above) - never a broad "$TMPDIR"/*.img glob. A glob
	# could delete another trial's freshly-truncated image out from
	# under its losetup -f, surfacing as the misleading
	#   losetup: <img>: failed to set up loop device: No such file or directory
	"$MDADM" --stop "$ms_dev" >/dev/null 2>&1 || true
	losetup -d "$la" >/dev/null 2>&1 || true
	losetup -d "$lb" >/dev/null 2>&1 || true
	rm -f "$fa" "$fb"
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
		# Serialize trials. Command substitution waits for run_trial to
		# fully exit - including its per-trial teardown - before the next
		# trial starts. Process substitution `< <(run_trial)` does NOT:
		# `read` returns after the first line while run_trial's cleanup
		# runs concurrently with the next trial's loop setup, racing it.
		trial_out="$(run_trial)"
		read -r eA eB d <<< "$trial_out"
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

# Always exit 0; this is a probe, and it is excluded from the pass/fail suite
# by its evidence_*.sh name (see the header). The D4 decision rule
# (max(delta_N)==0 AND max(delta_Y)>=2 over >=20 trials) is evaluated by the
# consumer of the JSON above, not here.
exit 0
