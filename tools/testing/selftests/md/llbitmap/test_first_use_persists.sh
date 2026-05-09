#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
#
# BITMAP_FIRST_USE bug: when llbitmap_init runs (first assemble of a
# freshly mdadm-created array), it clears BITMAP_FIRST_USE in
# llbitmap->flags (in memory) but the on-disk sb->state retains the
# bit until the next llbitmap_update_sb, which is normally invoked
# indirectly via md_update_sb on first metadata-dirtying write.
#
# If the array is stopped (or the host crashes) between RUN_ARRAY and
# the first md_update_sb, FIRST_USE remains set on disk. The next
# assemble re-runs llbitmap_init and clobbers any sync state.
#
# This test creates a fresh raid1 with --assume-clean (no writes) and
# stops it immediately. The expectation pre-fix is that sb->state on
# disk still has bit 3 (BITMAP_FIRST_USE = 8) set. Post-fix, it must
# be clear.
#
# We additionally check that sb->chunksize is the llbitmap-chosen
# value (not the mdadm placeholder), since llbitmap_update_sb writes
# both fields together.

set -eu

DIR="$(dirname "$0")"
. "$DIR/lib.sh"

llbitmap_require_root
llbitmap_require_modules
llbitmap_require_tools

LA=$(llbitmap_make_loop 100)
LB=$(llbitmap_make_loop 100)

llbitmap_alloc_ms_dev >/dev/null
MS_DEV="$LLBITMAP_TEST_MS_DEV"
MS_NAME="$LLBITMAP_TEST_MS_NAME"

echo "INFO: ms_dev=$MS_DEV members=$LA,$LB"

"$MDADM" --create "$MS_DEV" \
	--level=1 --metadata=1.2 --raid-devices=2 --homehost=any \
	--bitmap=auto --assume-clean "$LA" "$LB" --run --force >/dev/null 2>&1

# Confirm llbitmap is the active bitmap. If something else is selected
# this test is meaningless.
bt=$(cat "/sys/block/$MS_NAME/ms/bitmap_type" 2>/dev/null || echo "")
case "$bt" in
	*"[llbitmap]"*) : ;;
	*) llbitmap_skip "expected llbitmap, got '$bt'" ;;
esac

# Capture the in-memory llbitmap->chunksize chosen by llbitmap_init.
# This is what sb->chunksize SHOULD be after Fix 2 lands.
LLBITMAP_CHUNKSIZE=$(awk '/^chunksize /{print $2; exit}' "/sys/block/$MS_NAME/ms/llbitmap/metadata")
if [ -z "$LLBITMAP_CHUNKSIZE" ] || [ "$LLBITMAP_CHUNKSIZE" -le 0 ]; then
	llbitmap_fail "could not read llbitmap chunksize from sysfs"
fi
echo "INFO: in-memory llbitmap->chunksize = $LLBITMAP_CHUNKSIZE sectors"

# Stop the array IMMEDIATELY without any writes. This is the bug
# window: no write triggers md_update_sb, so the on-disk sb->state
# retains FIRST_USE.
"$MDADM" --stop "$MS_DEV" >/dev/null 2>&1

# Read sb->state and sb->chunksize from disk.
# Bitmap super at sb_start (4096) + bitmap_offset (sectors, at MD super
# byte 96) * 512.
SB_START=4096
BITMAP_OFFSET_SECTORS=$(dd if="$LA" bs=1 skip=$((SB_START + 96)) count=4 status=none | od -An -tu4 -N4 | tr -d ' ')
BITMAP_SUPER_BYTE=$(( SB_START + BITMAP_OFFSET_SECTORS * 512 ))

# bitmap_super_t layout (md-bitmap.h:36-52):
#   offset 48: __le32 state
#   offset 52: __le32 chunksize
SB_STATE=$(dd if="$LA" bs=1 skip=$((BITMAP_SUPER_BYTE + 48)) count=4 status=none | od -An -tu4 -N4 | tr -d ' ')
SB_CHUNKSIZE=$(dd if="$LA" bs=1 skip=$((BITMAP_SUPER_BYTE + 52)) count=4 status=none | od -An -tu4 -N4 | tr -d ' ')

echo "INFO: on-disk sb->state    = $SB_STATE (bit 3 = BITMAP_FIRST_USE = 8)"
echo "INFO: on-disk sb->chunksize = $SB_CHUNKSIZE"

# BITMAP_FIRST_USE = 3 -> mask = 1 << 3 = 8.
FIRST_USE_MASK=8
if [ $((SB_STATE & FIRST_USE_MASK)) -ne 0 ]; then
	llbitmap_fail "BITMAP_FIRST_USE persisted on disk after llbitmap_init: sb->state=$SB_STATE has bit 3 set"
fi

# Bonus assertion (Fix 2 also fixes this): on-disk sb->chunksize must
# match the llbitmap-chosen value, not whatever placeholder mdadm wrote
# at create time.
if [ "$SB_CHUNKSIZE" != "$LLBITMAP_CHUNKSIZE" ]; then
	llbitmap_fail "on-disk sb->chunksize=$SB_CHUNKSIZE does not match in-memory llbitmap->chunksize=$LLBITMAP_CHUNKSIZE"
fi

llbitmap_pass "sb->state=$SB_STATE (FIRST_USE clear) and sb->chunksize=$SB_CHUNKSIZE persisted correctly"
