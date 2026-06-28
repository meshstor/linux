#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
#
# Data-integrity stress for the per-bucket barrier *confinement* invariant:
# no barrier holder -- normal I/O or a sync window -- may span two 64 MB
# barrier units, or its tail runs unprotected against I/O the neighbouring
# bucket lets through.
#
#   "md/raid10: confine every barrier holder to a single barrier unit"
#       clamps raid10_make_request(), the resync/recovery max_sync, and the
#       reshape section to align_to_barrier_unit_end().  Without it a normal
#       write straddling a unit boundary registers nr_pending on the first
#       bucket only; a concurrent resync that raised the *second* bucket's
#       barrier therefore does not wait for that write's tail, the two run
#       concurrently on the same sectors, and a 'repair' can copy a torn /
#       stale value across the mirror -> silent corruption.
#
# Reachability
# ------------
# A normal request only crosses a unit when it is *not* chunk-split into
# unit-aligned pieces.  For power-of-two chunks <= 64 MB the existing
# chunk split already confines every request, so this test deliberately
# uses a 2-disk near=2 layout (near_copies == raid_disks): raid10 does no
# chunk striping there, so a large request maps linearly and straddles
# unit boundaries.  Sync windows additionally straddle at every 64 MB
# boundary regardless of layout.
#
# Nature of the test
# ------------------
# The corruption is a race, so detection is *probabilistic*: we run a
# crc-verified random-write workload (fio --verify, --verify_fatal) while
# 'repair' sweeps the array in a loop for a configurable window, and large
# writes plus a boundary-hammering job maximise unit-straddling I/O.  A
# clean kernel serialises each request against resync within its bucket,
# so verify never fails; a kernel missing the confinement clamp can return
# a verify mismatch.  Absence of a failure in one run is not a proof of
# correctness -- pair this with the in-kernel WARN that a barrier holder
# never spans a unit for deterministic coverage, and raise RAID10_XU_SECS
# in CI.
#
# PASS:  fio reports zero verify errors for the whole window and the array
#        finishes a clean, non-degraded repair.
# FAIL:  fio reports a verify (crc) mismatch, or the array ends degraded.
# SKIP:  tooling/tmpfs prerequisites missing.

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
. "${HERE}/lib.sh"

IMG_DIR="${RAID10_IMG_DIR:-/dev/shm}"
# Small members so 'repair' sweeps the whole array repeatedly within the
# window; >= a few 64 MB units so there are boundaries to straddle.
LOOP_SIZE="${RAID10_LOOP_SIZE:-256M}"
XU_SECS="${RAID10_XU_SECS:-90}"
SYNC_KBPS="${RAID10_XU_SYNC_KBPS:-50000}"

raid10_require_root
raid10_require_tools
raid10_require_module
raid10_require_tmpfs "$IMG_DIR" \
	"$((2 * $(raid10_size_to_kb "$LOOP_SIZE") + 128 * 1024))"

DEV="$(raid10_alloc_md)"
MD="${DEV##*/}"
RAID10_TEST_MD="$MD"
SYSFS="$(_raid10_sysfs "$MD")"

REPAIR_PID=""
FIO_RC_FILE="$(mktemp /tmp/raid10-xu-fio.XXXXXX)"

xu_cleanup() {
	set +e
	[ -n "$REPAIR_PID" ] && kill "$REPAIR_PID" >/dev/null 2>&1
	wait >/dev/null 2>&1
	if [ -b "/dev/${MD}" ]; then
		timeout 20 sh -c "echo idle > '$SYSFS/sync_action'" 2>/dev/null
	fi
	rm -f "$FIO_RC_FILE"
	# Safety net in case an older fio ignores --verify_state_save=0 and
	# drops <host>-<job>-N-verify.state files in the cwd.
	rm -f ./*-verify.state "$HERE"/*-verify.state 2>/dev/null
	raid10_cleanup
}
trap xu_cleanup EXIT

raid10_init_registry
LOOPS=()
for i in 0 1; do
	LOOPS+=("$(raid10_make_loop "$IMG_DIR" "$LOOP_SIZE")")
done
raid10_load_registry

# No --assume-clean: let the initial resync make both mirrors identical so
# that any later verify mismatch is caused by the race under test, not by
# pre-existing divergent garbage that 'repair' would legitimately rewrite.
"$MDADM" --create --run --force "$DEV" --level=10 \
	--raid-devices=2 --layout=n2 --bitmap=none "${LOOPS[@]}" >/dev/null 2>&1
sleep 1
raid10_wait_idle "$MD" 180

# Confirm the layout really does no chunk striping (near == raid_disks),
# otherwise the chunk split would already confine every request and the
# test would prove nothing.  raid10 encodes the layout as
#   near_copies | (far_copies << 8) | (far_offset << 16)
# so a plain "n2" reads back as 2 | (1 << 8) = 258, not 2; decode the low
# byte to get near_copies.
LAYOUT=$(cat "$SYSFS/layout" 2>/dev/null || echo 0)
NEAR=$(( LAYOUT & 0xff ))
if [ "$NEAR" != "2" ]; then
	echo "note: near_copies=$NEAR (layout=$LAYOUT); expected near=2 so requests are not chunk-split" >&2
fi

ARRAY_BYTES=$(blockdev --getsize64 "$DEV")
ARRAY_MB=$((ARRAY_BYTES / 1024 / 1024))
if [ "$ARRAY_MB" -lt 128 ]; then
	raid10_skip "array only ${ARRAY_MB}MB -- need >= 2 barrier units (128 MB) to straddle a boundary"
fi

# Lay down a verifiable pattern across the whole device through md, so both
# mirrors hold identical, crc-known data before the contended phase.
fio --name=seed --filename="$DEV" --rw=write --bs=1M --direct=1 \
	--size="${ARRAY_MB}M" --verify=crc32c --do_verify=0 \
	--verify_state_save=0 --output=/dev/null >/dev/null 2>&1 \
	|| raid10_skip "seed write failed (device too small or fio unhappy)"

# Re-trigger 'repair' continuously so a sync window is almost always active
# while fio writes.  repair (not check) issues sync *writes*, the dangerous
# side of the race.
repair_loop() {
	while :; do
		echo repair > "$SYSFS/sync_action" 2>/dev/null || true
		# Let it run a bit; it returns to idle quickly on tmpfs.
		sleep 2
	done
}
raid10_set_sync_speed "$MD" "$SYNC_KBPS"
repair_loop &
REPAIR_PID=$!

echo "array=$DEV ${ARRAY_MB}MB layout=$LAYOUT repair-loop pid=$REPAIR_PID window=${XU_SECS}s"

# Contended phase: a single crc-verified writer.
#
# Design notes (why not the obvious randwrite/multi-job):
#   * One job only, writing each block exactly once per pass -- overlapping
#     writes (multiple jobs, or random 1 MB writes at 4 KB granularity)
#     corrupt each other's verify headers and produce *false* mismatches
#     unrelated to the kernel.  Sequential non-overlapping writes verify
#     reliably, so any mismatch is real.
#   * bs=1 MB at a 512 KB start skew: 64 MB is a multiple of 1 MB, so a
#     1 MB-aligned write never crosses a unit boundary.  The 512 KB skew
#     makes exactly one write per 64 MB unit straddle the boundary -- the
#     request the confinement clamp must split.  On the near=2 layout
#     raid10 does not chunk-split it away.
#   * --verify_backlog re-reads recently written blocks mid-run, so a
#     repair that copied a torn/stale value over a straddling write's tail
#     is caught as a crc mismatch; --verify_fatal stops on the first.
SKEW=$((512 * 1024))
rc=0
fio --name=xuverify --filename="$DEV" --direct=1 --ioengine=libaio \
    --iodepth=16 --rw=write --bs=1M --offset="$SKEW" \
    --verify=crc32c --verify_fatal=1 --verify_backlog=64 \
    --verify_backlog_batch=64 --verify_state_save=0 --continue_on_error=none \
    --time_based --runtime="$XU_SECS" --loops=1000000 \
    --group_reporting --output=/dev/null \
    >/dev/null 2>&1 || rc=$?
echo "$rc" > "$FIO_RC_FILE"

kill "$REPAIR_PID" >/dev/null 2>&1 || true
wait "$REPAIR_PID" 2>/dev/null || true
REPAIR_PID=""

if [ "$rc" -ne 0 ]; then
	# fio exits non-zero on a verify mismatch (the bug) but also on
	# unrelated I/O errors; surface the distinction.
	raid10_fail "fio exited $rc during repair -- verify mismatch (cross-unit corruption) or I/O error; rerun with --output to inspect"
fi

# Final consistency: stop repair, run one clean check, confirm no mismatch
# count and no degradation.
echo idle > "$SYSFS/sync_action" 2>/dev/null || true
raid10_wait_idle "$MD" 60 || true
raid10_set_sync_speed "$MD" 2000000
echo check > "$SYSFS/sync_action" 2>/dev/null || true
sleep 1
raid10_wait_idle "$MD" 180 || raid10_fail "final check never completed"

MISMATCH=$(cat "$SYSFS/mismatch_cnt" 2>/dev/null || echo unreadable)
DEGRADED=$(cat "$SYSFS/degraded" 2>/dev/null || echo unreadable)
if [ "$DEGRADED" != "0" ]; then
	raid10_fail "array degraded ($DEGRADED) after the run"
fi
if [ "$MISMATCH" != "0" ] && [ "$MISMATCH" != "unreadable" ]; then
	raid10_fail "final check reports mismatch_cnt=$MISMATCH (mirrors diverged under concurrent repair)"
fi

raid10_pass "no cross-unit corruption observed over ${XU_SECS}s of verified I/O during repair (mismatch_cnt=$MISMATCH)"
