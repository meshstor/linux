#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
#
# Regression test for stale grown-chunk state after a shrink-then-regrow.
#
# llbitmap_resize() must initialise every newly-grown chunk [old_chunks,
# chunks) to BitUnwritten.  A shrink lowers llbitmap->chunks but leaves
# nr_pages at its high-water value, so a later regrow that stays within that
# high-water mark takes the grow == false path: no page is reallocated.  The
# buggy version cleared only the tail of the single page that holds old_chunks
# (memset clamped to one page).  When the regrow spanned a bitmap page
# boundary, the chunk-state bytes on the page(s) past that boundary kept the
# stale BitClean/BitDirty they carried when the array was larger -- persisted
# to disk by the post-resize flush and then read back by the resync/write path
# (skip_sync_blocks()/blocks_synced()), which treat Clean/Dirty differently
# from the intended Unwritten.
#
# The state is directly observable: /sys/block/<ms>/ms/llbitmap/bits counts
# chunks per state over [0, chunks).  This test creates a lockless RAID1 whose
# bitmap uses two pctl pages (chunks > PAGE_SIZE - BITMAP_DATA_OFFSET), writes
# the whole array so every chunk is non-Unwritten, then:
#   1) shrinks below the first pctl page boundary (chunks drop onto page 0,
#      nr_pages stays 2),
#   2) regrows back across the page boundary (grow == false, spans >= 2 pages).
# After the regrow the entire grown span [chunks_shrunk, chunks_regrown) must
# read back as Unwritten.  The buggy kernel leaves the chunks above the page
# boundary as stale Clean/Dirty, so the Unwritten count falls short by roughly
# one page of chunks.
#
# Verdict:
#   PASS  grown span reads back fully Unwritten; no oops.
#   FAIL  grown span short on Unwritten (stale Clean/Dirty survived), or oops.
#   SKIP  not llbitmap, PAGE_SIZE != 4096, component_size not writable, or the
#         geometry did not straddle the pctl page boundary on this kernel.

set -u

DIR="$(dirname "$0")"
. "$DIR/lib.sh"

llbitmap_require_root
llbitmap_require_modules
llbitmap_require_tools

# The reproducer needs the regrow to cross a pctl page boundary at a modest
# array size.  The first boundary sits at chunk (PAGE_SIZE - BITMAP_DATA_OFFSET)
# == 3072 for 4 KiB pages (BITMAP_DATA_OFFSET == 1024).  On larger pages the
# boundary chunk -- and thus the array -- would have to be far larger than a
# loop-backed selftest should allocate, so restrict to 4 KiB pages.
PAGE_SIZE=$(getconf PAGESIZE 2>/dev/null || echo 0)
[ "$PAGE_SIZE" = "4096" ] || llbitmap_skip "PAGE_SIZE=$PAGE_SIZE (test geometry assumes 4096)"

BITMAP_DATA_OFFSET=1024
BOUNDARY_CHUNK=$(( PAGE_SIZE - BITMAP_DATA_OFFSET ))	# first chunk on page 1

BITMAP_CHUNK_KIB=64
# Chunks chosen to bracket the page boundary:
#   shrunk  C1 = boundary - 1024  (= 2048) -> on page 0
#   regrown C2 = boundary + 1024  (= 4096) -> on page 1, nr_pages 2
C1_CHUNKS=$(( BOUNDARY_CHUNK - 1024 ))
C2_CHUNKS=$(( BOUNDARY_CHUNK + 1024 ))
C1_KIB=$(( C1_CHUNKS * BITMAP_CHUNK_KIB ))		# 131072 == 128 MiB
C2_KIB=$(( C2_CHUNKS * BITMAP_CHUNK_KIB ))		# 262144 == 256 MiB
C2_MB=$(( C2_KIB / 1024 ))				# 256
LOOP_MB=$(( C2_MB + 64 ))				# headroom for metadata/bitmap

LA=$(llbitmap_make_loop $LOOP_MB)
LB=$(llbitmap_make_loop $LOOP_MB)

llbitmap_alloc_ms_dev >/dev/null
MS_DEV="$LLBITMAP_TEST_MS_DEV"
MS_NAME="$LLBITMAP_TEST_MS_NAME"

echo "=== llbitmap shrink-then-regrow stale-state regression ==="
echo "  members: $LA $LB  ms: $MS_DEV  chunk: ${BITMAP_CHUNK_KIB}K"
echo "  boundary chunk: $BOUNDARY_CHUNK  shrink->${C1_CHUNKS}ch  regrow->${C2_CHUNKS}ch"

# Sum of all per-state counts == llbitmap->chunks (bits walks [0, chunks)).
bits_total() {
	awk '{s += $NF} END {print s + 0}' \
		"/sys/block/${MS_NAME}/ms/llbitmap/bits" 2>/dev/null || echo 0
}

# Create at the larger size so nr_pages == 2 from the start; the high-water
# nr_pages is what makes the later regrow take the grow == false path.
"$MDADM" --create "$MS_DEV" \
	--level=1 --metadata=1.2 --raid-devices=2 --homehost=any \
	--bitmap=lockless --bitmap-chunk=${BITMAP_CHUNK_KIB}K \
	--consistency-policy=bitmap --size=${C2_KIB} \
	--assume-clean "$LA" "$LB" --run --force >/dev/null 2>&1 \
	|| llbitmap_skip "mdadm create failed (size ${C2_KIB}K may exceed reserved bitmap space)"

bt=$(cat "/sys/block/$MS_NAME/ms/bitmap_type" 2>/dev/null || echo "")
case "$bt" in
	*"[llbitmap]"*) : ;;
	*) llbitmap_skip "expected llbitmap, got '$bt'" ;;
esac

CS_FILE="/sys/block/$MS_NAME/ms/component_size"
[ -w "$CS_FILE" ] || llbitmap_skip "component_size not writable: $CS_FILE"

"$MDADM" --wait "$MS_DEV" >/dev/null 2>&1 || true

CH0=$(bits_total)
echo "  chunks at create: $CH0"
[ "$CH0" -gt "$BOUNDARY_CHUNK" ] \
	|| llbitmap_skip "create chunks $CH0 <= boundary $BOUNDARY_CHUNK (nr_pages stayed 1)"

# Write the WHOLE array so every chunk is non-Unwritten (Dirty/Clean).  This is
# what makes the post-regrow Unwritten count attributable solely to the grown
# span: without it the discriminator could be masked by genuinely-unwritten
# chunks below the shrink point.
"$DD" if=/dev/urandom of="$MS_DEV" bs=1M count=$C2_MB oflag=direct conv=fsync \
	status=none || llbitmap_fail "initial full-array write failed"
sync

llbitmap_dmesg_clear

# 1) Shrink below the first pctl page boundary.  nr_pages stays at its
#    high-water value (2); the out-of-range chunk states are left in place.
echo "$C1_KIB" > "$CS_FILE" 2>/dev/null \
	|| llbitmap_skip "shrink to ${C1_KIB}K refused by component_size"
"$MDADM" --wait "$MS_DEV" >/dev/null 2>&1 || true
CH1=$(bits_total)
echo "  chunks after shrink: $CH1"
[ "$CH1" -lt "$BOUNDARY_CHUNK" ] \
	|| llbitmap_skip "shrink chunks $CH1 not below boundary $BOUNDARY_CHUNK"

# 2) Regrow back across the page boundary.  new_nr_pages (2) is not greater
#    than the high-water nr_pages (2), so this is the grow == false path.
echo "$C2_KIB" > "$CS_FILE" 2>/dev/null \
	|| llbitmap_fail "regrow to ${C2_KIB}K refused by component_size"
"$MDADM" --wait "$MS_DEV" >/dev/null 2>&1 || true
sync
CH2=$(bits_total)
echo "  chunks after regrow: $CH2"
[ "$CH2" -gt "$BOUNDARY_CHUNK" ] \
	|| llbitmap_skip "regrow chunks $CH2 did not cross boundary $BOUNDARY_CHUNK"

if llbitmap_dmesg_contains 'BUG: kernel NULL pointer' || \
   llbitmap_dmesg_contains 'Oops' || \
   llbitmap_dmesg_contains 'general protection fault'; then
	llbitmap_fail "oops observed in dmesg during shrink/regrow"
fi

# The whole grown span [CH1, CH2) must be Unwritten.  [0, CH1) was fully
# written above, so it contributes zero Unwritten -- the Unwritten count should
# therefore equal the grown span.  The buggy kernel only clears up to the page
# boundary, leaving (CH2 - BOUNDARY_CHUNK) stale Clean/Dirty chunks, so its
# Unwritten count is about one page of chunks short.
UNWRITTEN=$(llbitmap_state_count "$MS_NAME" "unwritten")
EXPECT_SPAN=$(( CH2 - CH1 ))
BUGGY_SPAN=$(( BOUNDARY_CHUNK - CH1 ))		# what the one-page clamp clears
TOL=16

echo "  bits after regrow:"
sed 's/^/    /' "/sys/block/${MS_NAME}/ms/llbitmap/bits" 2>/dev/null || true
echo "  unwritten=$UNWRITTEN  expected grown span=$EXPECT_SPAN  (buggy~=$BUGGY_SPAN)"

# Guard the discriminator: the span above the boundary must be non-trivial,
# otherwise fix and bug are indistinguishable.
[ $(( CH2 - BOUNDARY_CHUNK )) -ge $(( TOL * 4 )) ] \
	|| llbitmap_skip "grown span above boundary too small to discriminate"

if [ "$UNWRITTEN" -lt $(( EXPECT_SPAN - TOL )) ]; then
	llbitmap_fail "stale grown-chunk state: unwritten=$UNWRITTEN < grown span ${EXPECT_SPAN} (expected ~full span; one-page clamp would give ~${BUGGY_SPAN})"
fi

llbitmap_pass "regrow across pctl page boundary left grown span fully Unwritten (unwritten=$UNWRITTEN)"
