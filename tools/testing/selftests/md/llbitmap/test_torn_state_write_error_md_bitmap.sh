#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
#
# Reproducer for the md-bitmap (=internal) load-side state-mask fix:
#   "md/md-bitmap: mask sb->state on load to drop runtime-only bits".
#
# md_bitmap_read_sb() was OR-ing sb->state straight into runtime
# bitmap->flags with no mask.  A torn write that plants
# BITMAP_WRITE_ERROR (bit 2) on disk gets pulled into runtime flags
# and makes md_bitmap_create() fail with -EIO, leaving the array
# unbootable until the bitmap super is rewritten externally.
#
# Method:
#   1. Create raid1 with --bitmap=internal (selects md-bitmap backend).
#   2. Stop.
#   3. Forge bit 2 in sb->state on disk via direct dd.
#   4. Reassemble.
#   5. Drive a few md_update_sb cycles via small writes to advance
#      sb->events on disk.
#   6. Stop.  Verify final sb->state byte (bit 2 must be cleared by
#      the load-side mask + the existing write-side mask on first
#      md_update_sb).
#
# Verdict:
#   PASS  bit 2 forge has no observable effect (load mask in place;
#         array assembles, sb->events advances, bit cleared on disk).
#   FAIL  bit 2 forge persists on disk OR md_bitmap_create() fails
#         with -EIO (the load mask is missing or regressed).

set -u

DIR="$(dirname "$0")"
. "$DIR/lib.sh"

llbitmap_require_root
llbitmap_require_modules
llbitmap_require_tools

LOOP_SIZE_MB=100

bitmap_super_offset() {
	local dev="$1"
	local sb_start=4096
	local off
	off=$("$DD" if="$dev" bs=1 skip=$((sb_start + 96)) count=4 status=none |
	      od -An -tu4 -N4 | tr -d ' ')
	echo $(( sb_start + off * 512 ))
}

read_state_byte0() {
	local dev="$1"
	local sb_off
	sb_off=$(bitmap_super_offset "$dev")
	"$DD" if="$dev" bs=1 skip=$((sb_off + 48)) count=1 status=none | od -An -tu1 -N1 | tr -d ' '
}

write_state_byte0() {
	local dev="$1"
	local val="$2"
	local sb_off
	sb_off=$(bitmap_super_offset "$dev")
	printf "\\x$(printf '%02x' "$val")" | "$DD" of="$dev" bs=1 seek=$((sb_off + 48)) count=1 conv=notrunc status=none
}

read_events() {
	local dev="$1"
	local sb_off
	sb_off=$(bitmap_super_offset "$dev")
	"$DD" if="$dev" bs=1 skip=$((sb_off + 24)) count=8 status=none |
		python3 -c 'import sys; print(int.from_bytes(sys.stdin.buffer.read(8), "little"))'
}

LA=$(llbitmap_make_loop $LOOP_SIZE_MB)
LB=$(llbitmap_make_loop $LOOP_SIZE_MB)
llbitmap_alloc_ms_dev >/dev/null
MS_DEV="$LLBITMAP_TEST_MS_DEV"
MS_NAME="$LLBITMAP_TEST_MS_NAME"

echo "=== bitmap=internal: bit-2 forge reproducer ==="
echo "  members: $LA $LB  md: $MS_DEV"

# Force md-bitmap (legacy) backend via --bitmap=internal.
"$MDADM" --create "$MS_DEV" \
	--level=1 --metadata=1.2 --raid-devices=2 --homehost=any \
	--bitmap=internal --assume-clean "$LA" "$LB" --run --force \
	>/dev/null 2>&1 || llbitmap_skip "mdadm create failed"

bt=$(cat "/sys/block/$MS_NAME/ms/bitmap_type" 2>/dev/null || echo "")
case "$bt" in
	*"[bitmap]"*) : ;;
	*) llbitmap_skip "not md-bitmap ($bt)" ;;
esac

sync
sudo "$MDADM" --stop "$MS_DEV" >/dev/null 2>&1
udevadm settle 2>/dev/null

STATE_A=$(read_state_byte0 "$LA")
STATE_B=$(read_state_byte0 "$LB")
echo "  state byte0 before plant: A=$STATE_A B=$STATE_B"

# Set bit 2 (BITMAP_WRITE_ERROR) on both members; clear bit 3 (FIRST_USE)
NEW_A=$(( (STATE_A & ~8) | 4 ))
NEW_B=$(( (STATE_B & ~8) | 4 ))
write_state_byte0 "$LA" "$NEW_A"
write_state_byte0 "$LB" "$NEW_B"
sync
blockdev --flushbufs "$LA" 2>/dev/null || true
blockdev --flushbufs "$LB" 2>/dev/null || true

STATE_A_PLANTED=$(read_state_byte0 "$LA")
STATE_B_PLANTED=$(read_state_byte0 "$LB")
echo "  state byte0 after plant: A=$STATE_A_PLANTED B=$STATE_B_PLANTED (expect bit 0x04 set)"

EVENTS_BEFORE=$(read_events "$LA")
echo "  sb->events before assemble: $EVENTS_BEFORE"

sudo dmesg --clear 2>/dev/null || true
out=$(sudo "$MDADM" --assemble "$MS_DEV" "$LA" "$LB" --run 2>&1 || true)
echo "  assemble output: $out"
udevadm settle 2>/dev/null

# Drive several md_update_sb cycles
for i in $(seq 1 4); do
	"$DD" if=/dev/urandom of="$MS_DEV" bs=1M count=1 seek=$((i*5)) \
		oflag=direct status=none 2>/dev/null || true
	sync
	echo idle | sudo tee "/sys/block/$MS_NAME/ms/sync_action" >/dev/null 2>&1 || true
	sleep 0.3
done
sync

sudo "$MDADM" --stop "$MS_DEV" >/dev/null 2>&1
udevadm settle 2>/dev/null

EVENTS_AFTER=$(read_events "$LA")
STATE_A_FINAL=$(read_state_byte0 "$LA")
echo "  sb->events after writes+stop: $EVENTS_AFTER (was $EVENTS_BEFORE)"
echo "  state byte0 final on A: $STATE_A_FINAL"

# Check dmesg for diagnostic
echo "  --- dmesg ---"
sudo dmesg | tail -20 | grep -iE "bitmap|raid1|fail|error" | head -10

EVENTS_ADVANCED=0
[ "$EVENTS_AFTER" -gt "$EVENTS_BEFORE" ] && EVENTS_ADVANCED=1

BIT2_PERSISTS=$(( STATE_A_FINAL & 4 ))

echo
echo "=== verdict ==="
echo "  bit 2 still on disk after cycle: $BIT2_PERSISTS"
echo "  sb->events advanced ($EVENTS_BEFORE → $EVENTS_AFTER): $EVENTS_ADVANCED"

# md-bitmap masks WRITE_ERROR on the WRITE side in md_bitmap_update_sb(),
# so if we see bit 2 cleared from disk after a cycle, md_update_sb fired
# and properly cleared it via the existing write-mask.  That, combined
# with the load-side mask added by the production fix, closes the bug.
if [ "$BIT2_PERSISTS" -eq 0 ] && [ "$EVENTS_ADVANCED" -eq 1 ]; then
	echo "PASS: md-bitmap clears bit 2 via load+write masks"
	exit 0
elif [ "$BIT2_PERSISTS" -ne 0 ]; then
	echo "FAIL: bit 2 persists on disk -- load-side mask is missing"
	exit 1
else
	echo "FAIL: bit 2 cleared but events did not advance -- bitmap may be disabled"
	exit 1
fi
