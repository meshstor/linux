#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
#
# Regression test for the llbitmap_resize() use-after-free / data race on
# raid456 (CWE-416/CWE-362).
#
# llbitmap has a *lockless* IO data path: llbitmap_start_write()/end_write()
# index llbitmap->pctl[] with no lock.  On raid4/5/6 the bitmap update happens
# in md_account_bio() *before* the stripe-quiesce gate (raid5_get_active_stripe),
# and raid5_quiesce() only drains active_stripes -- it does not exclude a writer
# parked between the bitmap write and the gate.  A resize reached via the
# component_size sysfs attribute (size_store) runs under reconfig_mutex only and
# does NOT suspend the array.  Before the fix, llbitmap_resize() kfree()d the old
# pctl[] base while such a writer (or the daemon / unplug worker) could still be
# indexing it -> UAF, caught by KASAN as a use-after-free read, or a NULL/oops on
# a torn base load.
#
# The fix retires the old pctl[] base instead of freeing it (released only at
# destroy), annotates the lockless base reads with READ_ONCE() / a release-store
# publish, stops the daemon rearm-proof (BITMAP_RESIZING) and flushes the unplug
# workqueue across the swap.
#
# This test drives a raid5 grow repeatedly through the *unsuspended* sysfs
# component_size path while several writers hammer the array with O_DIRECT IO,
# crossing bitmap-page boundaries each step.  A KASAN kernel is required (and
# enforced below): the single-threaded grow_resize_pctl test cannot catch this
# race, and without KASAN a stale pctl[] read is silent.
#
# Verdict:
#   PASS  every grow-under-write step completed, no KASAN/UAF/oops in dmesg,
#         the untouched original region still verifies.
#   FAIL  KASAN/use-after-free/NULL-deref/oops in dmesg, or data corruption.
#   SKIP  not llbitmap, no CONFIG_KASAN, component_size not writable, grow
#         refused (-EINVAL: bitmap space too small at this chunk -- tune
#         MEMBER_MB/BITMAP_CHUNK), no grow step could be applied, or no
#         concurrent write landed (race never exercised).

set -u

DIR="$(dirname "$0")"
. "$DIR/lib.sh"

llbitmap_require_root
llbitmap_require_modules
llbitmap_require_tools

# The only UAF oracle is a KASAN splat in dmesg: on a non-KASAN kernel a
# stale pctl[] read is silent and the test would PASS having proven nothing.
kconf() {
	(zcat /proc/config.gz 2>/dev/null || cat "/boot/config-$(uname -r)" 2>/dev/null) \
		| grep -q "^$1=y"
}
kconf CONFIG_KASAN || llbitmap_skip "CONFIG_KASAN not enabled -- a UAF would not be diagnosed"

# raid5 needs >= 3 members.  Members are sized so several ~256 MiB-per-page
# (64 KiB chunk) boundaries are crossed as component_size grows, while staying
# under the reserved bitmap space (no chunksize doubling -> no -EINVAL).
MEMBER_MB=768
INIT_SIZE_MB=128	# initial per-device component size
STEP_MB=96		# per-device grow step (raid5 array grows ~2x this)
MAX_SIZE_MB=$((MEMBER_MB - 64))
BITMAP_CHUNK=64K
WRITERS=4
MARKER_MB=8		# original-region marker, never touched by the writers

LA=$(llbitmap_make_loop $MEMBER_MB)
LB=$(llbitmap_make_loop $MEMBER_MB)
LC=$(llbitmap_make_loop $MEMBER_MB)

llbitmap_alloc_ms_dev >/dev/null
MS_DEV="$LLBITMAP_TEST_MS_DEV"
MS_NAME="$LLBITMAP_TEST_MS_NAME"

echo "=== llbitmap resize race (raid5 grow under concurrent write) ==="
echo "  members: $LA $LB $LC  ms: $MS_DEV  chunk: $BITMAP_CHUNK"

"$MDADM" --create "$MS_DEV" \
	--level=5 --metadata=1.2 --raid-devices=3 --homehost=any \
	--bitmap=lockless --bitmap-chunk=$BITMAP_CHUNK \
	--consistency-policy=bitmap --size=${INIT_SIZE_MB}M \
	--assume-clean "$LA" "$LB" "$LC" --run --force >/dev/null 2>&1 \
	|| llbitmap_skip "mdadm create raid5 failed"

bt=$(cat "/sys/block/$MS_NAME/${LLBITMAP_SYSFS_SUBDIR}/bitmap_type" 2>/dev/null || echo "")
case "$bt" in
	*"[llbitmap]"*) : ;;
	*) llbitmap_skip "expected llbitmap, got '$bt'" ;;
esac

CS_FILE="/sys/block/$MS_NAME/${LLBITMAP_SYSFS_SUBDIR}/component_size"
[ -w "$CS_FILE" ] || llbitmap_skip "component_size not writable: $CS_FILE"

# Let the initial (assume-clean) state settle.
"$MDADM" --wait "$MS_DEV" >/dev/null 2>&1 || true

# Marker in the ORIGINAL region for an integrity check; the writers below never
# touch the first MARKER_MB MiB.
"$DD" if=/dev/urandom of=/tmp/llrace.marker bs=1M count=$MARKER_MB status=none
"$DD" if=/tmp/llrace.marker of="$MS_DEV" bs=1M count=$MARKER_MB oflag=direct \
	conv=fsync status=none
EXPECTED_MD5=$(md5sum /tmp/llrace.marker | awk '{print $1}')

llbitmap_dmesg_clear

# Background writers: random O_DIRECT 64 KiB writes within the *current* size,
# skipping the marker region.  They re-read the size each iteration so they keep
# hammering the freshly grown tail.
writer_stop="/tmp/llrace.stop.$$"
rm -f "$writer_stop"
# Engagement proof: each successful write appends one line.  Without it a
# run whose writes all fail (read-only array, size race) would still PASS
# having exercised zero write-vs-resize concurrency.
writer_progress=$(mktemp /tmp/llrace.progress.XXXXXX)
WRITER_PIDS=()
for w in $(seq 1 $WRITERS); do
	(
		while [ ! -e "$writer_stop" ]; do
			sz=$(blockdev --getsz "$MS_DEV" 2>/dev/null) || break
			[ -n "$sz" ] && [ "$sz" -gt 0 ] || { sleep 0.05; continue; }
			max_mb=$(( sz / 2048 ))			# 512B sectors -> MiB
			[ "$max_mb" -gt $((MARKER_MB + 8)) ] || { sleep 0.05; continue; }
			off=$(( (RANDOM % (max_mb - MARKER_MB - 4)) + MARKER_MB ))
			"$DD" if=/dev/zero of="$MS_DEV" bs=64K seek=$((off * 16)) \
				count=4 oflag=direct conv=fsync status=none \
				2>/dev/null && echo >> "$writer_progress" || true
		done
	) &
	WRITER_PIDS+=($!)
done

kasan_oops() {
	llbitmap_dmesg_contains 'KASAN' || \
	llbitmap_dmesg_contains 'use-after-free' || \
	llbitmap_dmesg_contains 'BUG: kernel NULL pointer' || \
	llbitmap_dmesg_contains 'Oops' || \
	llbitmap_dmesg_contains 'general protection fault'
}

stop_writers() {
	touch "$writer_stop"
	for p in "${WRITER_PIDS[@]:-}"; do
		wait "$p" 2>/dev/null || true
	done
}

# Grow the per-device component_size in steps via sysfs (size_store: the
# unsuspended path) while the writers run.  Each step crosses one or more bitmap
# pages, exercising the pctl[] swap against the live lockless readers.
grew=0
size_mb=$INIT_SIZE_MB
while [ "$size_mb" -lt "$MAX_SIZE_MB" ]; do
	size_mb=$(( size_mb + STEP_MB ))
	[ "$size_mb" -le "$MAX_SIZE_MB" ] || size_mb=$MAX_SIZE_MB
	kib=$(( size_mb * 1024 ))

	if ! echo "$kib" > "$CS_FILE" 2>/dev/null; then
		# Stop on the first refused step; if none succeeded, SKIP below.
		break
	fi
	grew=$(( grew + 1 ))
	"$MDADM" --wait "$MS_DEV" >/dev/null 2>&1 || true

	if kasan_oops; then
		stop_writers
		llbitmap_fail "KASAN/oops during grow-under-write (step $grew, ${size_mb}M)"
	fi
done

stop_writers
sync

[ "$grew" -gt 0 ] || llbitmap_skip "no grow step applied (sizes too small / refused)"

writes_done=$(wc -l < "$writer_progress" 2>/dev/null || echo 0)
[ "$writes_done" -gt 0 ] || \
	llbitmap_skip "no concurrent write completed -- race never exercised"

echo "  applied $grew grow steps under $WRITERS concurrent writers ($writes_done writes landed)"

if kasan_oops; then
	llbitmap_fail "KASAN/oops observed in dmesg after grow-under-write"
fi

ACTUAL_MD5=$("$DD" if="$MS_DEV" bs=1M count=$MARKER_MB iflag=direct status=none \
	| md5sum | awk '{print $1}')
[ "$ACTUAL_MD5" = "$EXPECTED_MD5" ] \
	|| llbitmap_fail "original-region data mismatch: $ACTUAL_MD5 != $EXPECTED_MD5"

rm -f /tmp/llrace.marker "$writer_stop" "$writer_progress"
llbitmap_pass "raid5 survived $grew grow-under-write resizes; no KASAN/oops; data intact"
