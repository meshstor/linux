#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
#
# A discard larger than one barrier unit must not leak an md_write_start()
# reference (writes_pending) or a per-bucket barrier.
#
# Why this exists
# ---------------
# raid10_handle_discard() takes a per-bucket barrier on the unit the
# discard *starts* in (wait_barrier() -> nr_pending[idx]), but a single
# discard bio can span gigabytes -- many 64 MB barrier units.  Two
# commits in the per-bucket series are responsible for keeping the
# accounting balanced across such a discard:
#
#   "md/raid10: confine every barrier holder to a single barrier unit"
#       splits an oversized discard at the unit boundary and resubmits
#       both halves; each half re-enters raid10_make_request() and takes
#       its own md_write_start()/barrier, so the original call must drop
#       its own md_write_start() reference with md_write_end().  Get that
#       wrong and *every* discard > 64 MB leaks one writes_pending
#       reference -- the array then never returns to the 'clean' state.
#
#   "md/raid10: drop the held barrier when a discard split fails"
#       restores the allow_barrier() the conversion dropped from the
#       bio_split() error legs.  A leaked barrier leaves nr_pending[idx]
#       (or nr_sync_pending) non-zero forever, so the next freeze_array()
#       -- a quiesce, a suspend, an array stop -- wedges.
#
# Both failure modes are deterministically observable from userspace, so
# unlike the corruption-class confinement bugs this needs no statistics:
#
#   * writes_pending leak  -> after an idle multi-unit blkdiscard the
#                             array stays 'active'/'write-pending' instead
#                             of dropping back to 'clean'.
#   * barrier leak         -> a freeze triggered afterwards (we use a
#                             transient 'mdadm --readonly' ->
#                             __md_stop_writes() -> raid10_quiesce(1) ->
#                             freeze_array()) blocks forever, because
#                             freeze waits for get_unqueued_pending() == 0.
#
# PASS:  array returns to 'clean' after each oversized discard, and the
#        post-discard freeze (readonly toggle) completes promptly.
# FAIL:  array stuck dirty (writes_pending leak) or the freeze hangs
#        (barrier leak).
# SKIP:  discard not supported by the backing devices, or tooling/tmpfs
#        prerequisites missing.

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
. "${HERE}/lib.sh"

IMG_DIR="${RAID10_IMG_DIR:-/dev/shm}"
LOOP_SIZE="${RAID10_LOOP_SIZE:-512M}"
# Discard length: must exceed one 64 MB barrier unit so the unit-boundary
# split path runs; a few units exercises several requeues.
DISCARD_MB="${RAID10_DISCARD_MB:-256}"
ITERS="${RAID10_DISCARD_ITERS:-5}"
CLEAN_TIMEOUT="${RAID10_CLEAN_TIMEOUT:-20}"

raid10_require_root
raid10_require_tools
raid10_require_module
if ! command -v blkdiscard >/dev/null 2>&1; then
	raid10_skip "missing tool: blkdiscard"
fi
# 4 loop images plus 256 MB slack.
raid10_require_tmpfs "$IMG_DIR" \
	"$((4 * $(raid10_size_to_kb "$LOOP_SIZE") + 256 * 1024))"

DEV="$(raid10_alloc_md)"
MD="${DEV##*/}"
RAID10_TEST_MD="$MD"
SYSFS="$(_raid10_sysfs "$MD")"

raid10_init_registry
LOOPS=()
for i in 0 1 2 3; do
	LOOPS+=("$(raid10_make_loop "$IMG_DIR" "$LOOP_SIZE")")
done
raid10_load_registry

# --assume-clean is fine here: this test inspects barrier/writes_pending
# accounting, not data, so we do not need the members to be in sync.
"$MDADM" --create --run --force --assume-clean "$DEV" --level=10 \
	--raid-devices=4 --layout=n2 --bitmap=none "${LOOPS[@]}" >/dev/null 2>&1
sleep 1
raid10_wait_idle "$MD"

# Make the active->clean transition prompt and, crucially, *possible*: a
# safe_mode_delay of 0 disables auto-clean entirely, which would look like
# a writes_pending leak.  Pin a small non-zero delay.
echo 1 > "$SYSFS/safe_mode_delay" 2>/dev/null || true

# Discard must actually reach the personality, else the test proves
# nothing.
DMAX=$(cat "/sys/block/${MD}/queue/discard_max_bytes" 2>/dev/null || echo 0)
if [ "${DMAX:-0}" -eq 0 ]; then
	raid10_skip "raid10 array advertises no discard (backing loops on $IMG_DIR lack discard)"
fi

ARRAY_BYTES=$(blockdev --getsize64 "$DEV")
DISCARD_BYTES=$((DISCARD_MB * 1024 * 1024))
if [ "$DISCARD_BYTES" -ge "$ARRAY_BYTES" ]; then
	# Keep some slack so a non-zero start offset still fits.
	DISCARD_BYTES=$(( (ARRAY_BYTES / 2) & ~((1 << 20) - 1) ))
fi
if [ "$DISCARD_BYTES" -le $((64 * 1024 * 1024)) ]; then
	raid10_fail "array too small ($ARRAY_BYTES bytes) to issue a >64 MB discard"
fi

# Poll array_state until it reports 'clean'.  Returns non-zero on timeout.
wait_clean() {
	local i state
	for i in $(seq 1 $((CLEAN_TIMEOUT * 2))); do
		state=$(cat "$SYSFS/array_state" 2>/dev/null || echo gone)
		case "$state" in
			clean|read-auto) return 0 ;;
		esac
		sleep 0.5
	done
	return 1
}

# Baseline: a freshly created array should settle to clean.
if ! wait_clean; then
	raid10_fail "array never reached 'clean' before any discard (state=$(cat "$SYSFS/array_state" 2>/dev/null))"
fi

echo "array=$DEV size=$((ARRAY_BYTES / 1024 / 1024))MB discard=$((DISCARD_BYTES / 1024 / 1024))MB iters=$ITERS"

for it in $(seq 1 "$ITERS"); do
	# Vary the start so the discard does not always begin unit-aligned;
	# a 1 MB-offset discard still spans multiple units and exercises the
	# leading-unit split with a non-zero in-unit remainder.
	off=$(( (it % 2) * 1024 * 1024 ))
	len=$DISCARD_BYTES
	if [ $((off + len)) -gt "$ARRAY_BYTES" ]; then
		len=$(( (ARRAY_BYTES - off) & ~((1 << 20) - 1) ))
	fi
	if ! blkdiscard --offset "$off" --length "$len" "$DEV" 2>/dev/null; then
		# The array advertised discard (discard_max_bytes != 0, checked
		# above), so a failing blkdiscard here is the advertised discard not
		# working -- the harness cannot exercise the per-unit split path.
		# FAIL, not a green-tolerated SKIP.  (The "advertises no discard"
		# case is the legitimate SKIP, at the discard_max_bytes gate above.)
		raid10_fail "blkdiscard failed (offset=$off len=$len) despite discard_max_bytes=$DMAX -- advertised discard did not work; cannot exercise the barrier-unit split"
	fi
	if ! wait_clean; then
		state=$(cat "$SYSFS/array_state" 2>/dev/null || echo gone)
		raid10_fail "iter $it: array stuck '$state' ${CLEAN_TIMEOUT}s after a $((len / 1024 / 1024))MB discard (md_write_start/end leaked per unit split)"
	fi
	printf 'iter %d: discard %dMB @ %dMB -> clean\n' \
		"$it" "$((len / 1024 / 1024))" "$((off / 1024 / 1024))"
done

# Barrier-leak probe: a leaked per-bucket barrier leaves
# get_unqueued_pending() non-zero, so freeze_array() never returns.  A
# transient 'readonly' runs __md_stop_writes() -> raid10_quiesce(1) ->
# freeze_array(); if it cannot complete in 30s the array has a stuck
# barrier from the discard path.
if ! timeout 30 "$MDADM" --readonly "$DEV" >/dev/null 2>&1; then
	raid10_fail "freeze (mdadm --readonly) wedged after discards -- a per-bucket barrier was leaked"
fi
timeout 30 "$MDADM" --readwrite "$DEV" >/dev/null 2>&1 || true

raid10_pass "oversized discards left no writes_pending or barrier leak (array returned clean, freeze completed)"
