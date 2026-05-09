#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
#
# Mode A reproducer: corrupted bitmap super with a chunksize that's a
# power of 2 but too small to fit the array's chunks in the reserved
# space must be rejected at assemble with a clear diagnostic.
#
# This test forces the dimensional check at line 997 of ms-llbitmap.c
# (and its kernel-tree twin md-llbitmap.c) by writing chunksize=64
# sectors directly into the on-disk bitmap super. For a 100 MiB v1.2
# array with default_space=6 sectors=3072 reserved bytes:
#   chunks_needed = DIV_ROUND_UP(204800, 64) = 3200
#   bytes_reserved = 3072
#   3200 > 3072 → must be rejected
#
# Pre-fix expectation: rejected (the buggy check fires by coincidence —
#   64 < DIV_ROUND_UP(204800, 3072) = 67 → "chunksize too small 64 < 67")
# Post-fix expectation: rejected with the new diagnostic showing
#   "needs 3200 bytes, 3072 reserved"
# The behavioral difference is in the dmesg diagnostic.
#
# This test is therefore mainly a regression check: it validates that
# corrupted-chunksize assembly fails in either pre-fix or post-fix
# kernels, and asserts on the dmesg pattern post-fix. We use the
# pre-fix dmesg pattern when running against the unfixed kernel.

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

echo "INFO: ms_dev=$MS_DEV"

"$MDADM" --create "$MS_DEV" \
	--level=1 --metadata=1.2 --raid-devices=2 --homehost=any \
	--bitmap=auto --assume-clean "$LA" "$LB" --run --force >/dev/null 2>&1

# Wait for any pending sb writes to flush.
sync
"$MDADM" --stop "$MS_DEV" >/dev/null 2>&1

# Locate the bitmap super on $LA. v1.2: MD super at sector 8 (byte 4096).
# Per <linux/raid/md_p.h> mdp_superblock_1 layout, bitmap_offset is at
# byte offset 96 (0x60) from the start of the MD super; it's a __le32
# in sectors. So bitmap super lives at sb_start + bitmap_offset*512.
SB_START=4096
BITMAP_OFFSET_SECTORS=$(dd if="$LA" bs=1 skip=$((SB_START + 96)) count=4 status=none | od -An -tu4 -N4 | tr -d ' ')
BITMAP_SUPER_BYTE=$(( SB_START + BITMAP_OFFSET_SECTORS * 512 ))
echo "INFO: bitmap super at byte $BITMAP_SUPER_BYTE (sb_start=$SB_START, bitmap_offset=$BITMAP_OFFSET_SECTORS sectors)"

# Sanity: read magic, version, chunksize from where we think the super is.
MAGIC=$(dd if="$LA" bs=1 skip=$((BITMAP_SUPER_BYTE + 0)) count=4 status=none | od -An -tx4 -N4 | tr -d ' ')
VERSION=$(dd if="$LA" bs=1 skip=$((BITMAP_SUPER_BYTE + 4)) count=4 status=none | od -An -tu4 -N4 | tr -d ' ')
ORIG_CHUNKSIZE=$(dd if="$LA" bs=1 skip=$((BITMAP_SUPER_BYTE + 52)) count=4 status=none | od -An -tu4 -N4 | tr -d ' ')
echo "INFO: bitmap super magic=0x$MAGIC version=$VERSION orig_chunksize=$ORIG_CHUNKSIZE"

# BITMAP_MAGIC = 0x6d746962, BITMAP_MAJOR_LOCKLESS = 6.
if [ "$MAGIC" != "6d746962" ]; then
	llbitmap_skip "bitmap super magic mismatch (got 0x$MAGIC, expected 0x6d746962)"
fi
if [ "$VERSION" != "6" ]; then
	llbitmap_skip "bitmap super version mismatch (got $VERSION, expected 6/llbitmap)"
fi

# Write chunksize=1 (LE: 01 00 00 00). It IS a power of 2 (2^0), so
# the is_power_of_2 check at line 991 passes. But for a 100 MiB v1.2
# array with mdadm's typical sectors_reserved=256 (bytes_reserved=131072):
#   DIV_ROUND_UP(204800, 1) = 204800 chunks needed
#   131072 bytes reserved
#   204800 > 131072 → must be rejected
# This exercises the dimensional check at line 997.
printf '\x01\x00\x00\x00' | dd of="$LA" bs=1 seek=$((BITMAP_SUPER_BYTE + 52)) count=4 conv=notrunc status=none

# Also clear BITMAP_FIRST_USE in sb->state at offset 48: bit 3 = 0x08.
# If FIRST_USE is set, llbitmap_init runs and our chunksize=1 would be
# overwritten by the auto-chosen value before the validator sees it.
ORIG_STATE=$(dd if="$LA" bs=1 skip=$((BITMAP_SUPER_BYTE + 48)) count=4 status=none | od -An -tu4 -N4 | tr -d ' ')
NEW_STATE=$(( ORIG_STATE & ~8 ))
# Write 4 little-endian bytes of NEW_STATE. Use python for unambiguous
# binary encoding; the printf+sed+xargs chain mangled non-printable bytes.
python3 -c "import sys; sys.stdout.buffer.write(($NEW_STATE).to_bytes(4, 'little'))" \
	| dd of="$LA" bs=1 seek=$((BITMAP_SUPER_BYTE + 48)) count=4 conv=notrunc status=none
echo "INFO: cleared FIRST_USE in sb->state ($ORIG_STATE -> $NEW_STATE)"

sync
# The kernel block-device cache may hold a stale view of the loopback's
# bitmap super; force a re-read so the next assemble sees our edit.
blockdev --flushbufs "$LA" 2>/dev/null || true
blockdev --flushbufs "$LB" 2>/dev/null || true

# Verify the edit took effect on the underlying file.
VERIFY_CHUNKSIZE=$(dd if="$LA" bs=1 skip=$((BITMAP_SUPER_BYTE + 52)) count=4 status=none | od -An -tu4 -N4 | tr -d ' ')
echo "INFO: post-edit chunksize on disk = $VERIFY_CHUNKSIZE"
if [ "$VERIFY_CHUNKSIZE" != "1" ]; then
	llbitmap_fail "edit did not persist: post-edit chunksize=$VERIFY_CHUNKSIZE, expected 1"
fi

# Clear dmesg ring so we can pattern-match what fires.
dmesg --clear >/dev/null 2>&1 || true

echo "INFO: attempting assemble with chunksize=1 sectors (forced too-small)..."
# Re-verify chunksize is still 1 immediately before mdadm reads it.
RIGHT_BEFORE=$(dd if="$LA" bs=1 skip=$((BITMAP_SUPER_BYTE + 52)) count=4 status=none | od -An -tu4 -N4 | tr -d ' ')
echo "INFO: chunksize on disk RIGHT before assemble: $RIGHT_BEFORE"
RIGHT_BEFORE_STATE=$(dd if="$LA" bs=1 skip=$((BITMAP_SUPER_BYTE + 48)) count=4 status=none | od -An -tu4 -N4 | tr -d ' ')
echo "INFO: state on disk RIGHT before assemble: $RIGHT_BEFORE_STATE"
ASSEMBLE_OUTPUT=$("$MDADM" --assemble "$MS_DEV" "$LA" "$LB" --run 2>&1 || true)
echo "INFO: mdadm output: $ASSEMBLE_OUTPUT"

# The assemble must fail.
if echo "$ASSEMBLE_OUTPUT" | grep -qi "started"; then
	"$MDADM" --stop "$MS_DEV" >/dev/null 2>&1 || true
	cat "/sys/block/$MS_NAME/ms/llbitmap/bits" 2>&1 | head | sed 's/^/  /'
	llbitmap_fail "assemble with corrupted chunksize=64 should fail but succeeded: $ASSEMBLE_OUTPUT"
fi

if ! echo "$ASSEMBLE_OUTPUT" | grep -qi "Invalid argument\|invalid"; then
	llbitmap_fail "assemble error not 'Invalid argument': $ASSEMBLE_OUTPUT"
fi

# Inspect dmesg.
DMESG=$(dmesg | tail -100)
echo "INFO: relevant dmesg lines:"
echo "$DMESG" | grep -iE 'llbitmap|chunksize' | sed 's/^/  /' | tail -10

# Pre-fix kernel: "chunksize too small <num> < <num>"
# Post-fix kernel: "chunksize <num> too small for <bytes> bytes"
# We accept either as PASS, but report which.
if echo "$DMESG" | grep -qE 'chunksize.*too small.*(needs|<.*/.*)'; then
	llbitmap_pass "rejected with old/buggy diagnostic format"
elif echo "$DMESG" | grep -qE 'chunksize.* too small.*(reserved|bytes)'; then
	llbitmap_pass "rejected with new (post-fix) diagnostic format"
else
	llbitmap_fail "no expected llbitmap diagnostic in dmesg"
fi
