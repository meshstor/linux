#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
#
# Regression test for the llbitmap grow-resize NULL-deref panic.
#
# llbitmap_resize() must grow the per-page control array (pctl[]/nr_pages)
# when an array grows across a bitmap page boundary. Before the fix,
# llbitmap_resize() only bumped chunkshift/chunksize/chunks; the post-grow
# resync and any write to the new region indexed pctl[page_idx] past the old
# array, dereferenced NULL, and panicked the kernel.
#
# This test grows a lockless RAID1 from ~159 MiB (chunks ~2544, nr_pages 1)
# to ~319 MiB (chunks ~5104, nr_pages 2) with a 64 KiB bitmap chunk, so the
# grow crosses the pctl page boundary at chunk 3073. It then writes into the
# new region and verifies pre-existing data, asserting no oops/panic.
#
# Verdict:
#   PASS  grow succeeds, resync completes, new-region write succeeds,
#         pre-existing data verifies, no oops in dmesg.
#   FAIL  oops/NULL-deref observed in dmesg (or, pre-fix, the host panics).
#   SKIP  not llbitmap, or grow refused with -EINVAL (bitmap space too small
#         for these sizes on this kernel — tune LOOP_*_MB / bitmap-chunk).

set -u

DIR="$(dirname "$0")"
. "$DIR/lib.sh"

llbitmap_require_root
llbitmap_require_modules
llbitmap_require_tools

# Sized so chunks cross the pctl page boundary (3073 chunks @ 64K) on grow,
# while staying well under typical reserved bitmap space (no chunksize doubling).
LOOP_INIT_MB=160
LOOP_GROWN_MB=320
BITMAP_CHUNK=64K

LA=$(llbitmap_make_loop $LOOP_INIT_MB)
LB=$(llbitmap_make_loop $LOOP_INIT_MB)

llbitmap_alloc_ms_dev >/dev/null
MS_DEV="$LLBITMAP_TEST_MS_DEV"
MS_NAME="$LLBITMAP_TEST_MS_NAME"

echo "=== llbitmap grow-resize pctl regression ==="
echo "  members: $LA $LB  ms: $MS_DEV  chunk: $BITMAP_CHUNK"

"$MDADM" --create "$MS_DEV" \
	--level=1 --metadata=1.2 --raid-devices=2 --homehost=any \
	--bitmap=lockless --bitmap-chunk=$BITMAP_CHUNK \
	--consistency-policy=bitmap \
	--assume-clean "$LA" "$LB" --run --force >/dev/null 2>&1 \
	|| llbitmap_skip "mdadm create failed"

bt=$(cat "/sys/block/$MS_NAME/ms/bitmap_type" 2>/dev/null || echo "")
case "$bt" in
	*"[llbitmap]"*) : ;;
	*) llbitmap_skip "expected llbitmap, got '$bt'" ;;
esac

# Write a marker into the ORIGINAL region (first 8 MiB) for integrity check.
dd if=/dev/urandom of=/tmp/llgrow.marker bs=1M count=8 status=none
dd if=/tmp/llgrow.marker of="$MS_DEV" bs=1M count=8 oflag=direct conv=fsync status=none
EXPECTED_MD5=$(md5sum /tmp/llgrow.marker | awk '{print $1}')

SIZE_BEFORE=$(blockdev --getsize64 "$MS_DEV")
echo "  array size before grow: $SIZE_BEFORE bytes"

llbitmap_dmesg_clear

# Grow both loop backing files and refresh loop capacity, then grow the array
# across the pctl page boundary.  The backing files are derived from the loop
# devices via losetup -- the lib.sh LLBITMAP_TEST_{FILES,LOOPS} globals are
# populated inside the $(...) that created the loop and do not propagate here.
for loop in "$LA" "$LB"; do
	img=$(losetup -O BACK-FILE -n "$loop" | tr -d '[:space:]')
	[ -n "$img" ] || llbitmap_fail "could not resolve backing file for $loop"
	truncate -s "${LOOP_GROWN_MB}M" "$img"
	losetup -c "$loop"
done

grow_out=$("$MDADM" --grow "$MS_DEV" --size=max 2>&1) || {
	# SKIP only on the kernel's own chunksize-doubling refusal, identified
	# by its dmesg signature.  Matching mdadm's generic 'invalid' output
	# here would also swallow a regression that makes resize spuriously
	# refuse a valid grow -- silently de-activating this test's coverage.
	if llbitmap_dmesg_contains 'would need chunksize'; then
		llbitmap_skip "grow refused (chunksize would change) — tune sizes: $grow_out"
	fi
	llbitmap_fail "mdadm --grow failed: $grow_out"
}

# Let the post-grow resync finish (new region is Unwritten => mostly skipped).
"$MDADM" --wait "$MS_DEV" >/dev/null 2>&1 || true
sync

SIZE_AFTER=$(blockdev --getsize64 "$MS_DEV")
echo "  array size after grow:  $SIZE_AFTER bytes"
[ "$SIZE_AFTER" -gt "$SIZE_BEFORE" ] \
	|| llbitmap_fail "array did not grow ($SIZE_BEFORE -> $SIZE_AFTER); loop resize/--grow ineffective"

# Exercise the NEW region: write into the grown tail (8 MiB past the old end).
NEW_SEEK_MB=$(( SIZE_BEFORE / 1048576 + 8 ))
dd if=/dev/urandom of="$MS_DEV" bs=1M seek=$NEW_SEEK_MB count=16 oflag=direct conv=fsync status=none \
	|| llbitmap_fail "write into grown region failed"
sync

# Assertions.
if llbitmap_dmesg_contains 'BUG: kernel NULL pointer' || \
   llbitmap_dmesg_contains 'Oops' || \
   llbitmap_dmesg_contains 'general protection fault'; then
	llbitmap_fail "oops observed in dmesg after grow"
fi

ACTUAL_MD5=$(dd if="$MS_DEV" bs=1M count=8 iflag=direct status=none | md5sum | awk '{print $1}')
[ "$ACTUAL_MD5" = "$EXPECTED_MD5" ] \
	|| llbitmap_fail "original-region data mismatch: $ACTUAL_MD5 != $EXPECTED_MD5"

rm -f /tmp/llgrow.marker
llbitmap_pass "grow crossed pctl page boundary with no crash; data intact"
