#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
#
# Reproducer for the llbitmap (lockless) load-side state-mask fix:
#   "md/llbitmap: mask sb->state on load to drop runtime-only bits".
#
# This is the llbitmap sibling of test_torn_state_write_error_md_bitmap.sh.
# llbitmap_read_sb() used to copy sb->state straight into runtime
# llbitmap->flags with no mask.  A torn write that plants
# BITMAP_WRITE_ERROR (bit 2) on disk gets pulled into runtime flags;
# llbitmap_enabled() then returns false for the array's whole lifetime.
# Unlike md-bitmap (which fails md_bitmap_create() with -EIO and refuses
# to assemble), llbitmap assembles SILENTLY with the bitmap disabled:
#   - /sys/block/<ms>/ms/llbitmap/bits prints "bitmap io error"
#   - llbitmap_update_sb() early-returns, so on-disk sb->events freezes
#   - the next clean reassemble forces a full resync (stale events)
# with no log line attributing the cause.  This silent-denial-of-bitmap
# is strictly worse than the md-bitmap -EIO it mirrors, yet had no test.
#
# Method:
#   1. Create raid1 with --bitmap=auto (selects the llbitmap backend).
#   2. Stop.
#   3. Forge bit 2 (WRITE_ERROR) in sb->state on disk via direct dd,
#      clearing bit 3 (FIRST_USE) so read_sb takes the normal load path
#      (a set FIRST_USE diverts into llbitmap_init re-initialisation).
#   4. Reassemble.
#   5. Drive a few md_update_sb cycles via small writes.
#   6. Verify the bitmap is alive (bits != "bitmap io error") and
#      sb->events advanced.
#
# Verdict:
#   PASS  bitmap alive after load (bits readable, not "bitmap io error")
#         AND sb->events advanced -> the load-side mask dropped bit 2.
#   FAIL  bits reports "bitmap io error" (bitmap disabled) OR sb->events
#         froze -> the load-side mask is missing or regressed.

set -u

DIR="$(dirname "$0")"
. "$DIR/lib.sh"

llbitmap_require_root
llbitmap_require_modules
llbitmap_require_tools
command -v python3 >/dev/null 2>&1 || llbitmap_skip "python3 not available"

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

echo "=== bitmap=auto (llbitmap): bit-2 forge reproducer ==="
echo "  members: $LA $LB  md: $MS_DEV"

# --bitmap=auto selects llbitmap on a meshstor-ms build.
"$MDADM" --create "$MS_DEV" \
	--level=1 --metadata=1.2 --raid-devices=2 --homehost=any \
	--bitmap=auto --assume-clean "$LA" "$LB" --run --force \
	>/dev/null 2>&1 || llbitmap_skip "mdadm create failed"

bt=$(cat "/sys/block/$MS_NAME/${LLBITMAP_SYSFS_SUBDIR}/bitmap_type" 2>/dev/null || echo "")
case "$bt" in
	*"[llbitmap]"*) : ;;
	*) llbitmap_skip "not llbitmap ($bt)" ;;
esac

sync
sudo "$MDADM" --stop "$MS_DEV" >/dev/null 2>&1
udevadm settle 2>/dev/null

# The bit-identical superblock makes the in-tree md_mod auto-assemble LA/LB the
# moment they reappear after --stop; that array holds the members and its page
# cache shadows a direct read of the loops.  Stop it and drop caches so the
# bit-2 plant lands on the real on-disk bitmap super.
llbitmap_stop_inkernel_md "$LA" "$LB"
blockdev --flushbufs "$LA" 2>/dev/null || true
blockdev --flushbufs "$LB" 2>/dev/null || true

STATE_A=$(read_state_byte0 "$LA")
STATE_B=$(read_state_byte0 "$LB")
echo "  state byte0 before plant: A=$STATE_A B=$STATE_B"

# Set bit 2 (BITMAP_WRITE_ERROR = 0x04); clear bit 3 (FIRST_USE = 0x08)
# so read_sb takes the normal load path rather than re-running init.
NEW_A=$(( (STATE_A & ~8) | 4 ))
NEW_B=$(( (STATE_B & ~8) | 4 ))
write_state_byte0 "$LA" "$NEW_A"
write_state_byte0 "$LB" "$NEW_B"
sync
blockdev --flushbufs "$LA" 2>/dev/null || true
blockdev --flushbufs "$LB" 2>/dev/null || true

STATE_A_PLANTED=$(read_state_byte0 "$LA")
STATE_B_PLANTED=$(read_state_byte0 "$LB")
echo "  state byte0 after plant: A=$STATE_A_PLANTED B=$STATE_B_PLANTED (expect bit 0x04 set, 0x08 clear)"

# Prove the injection actually landed BEFORE any verdict.  The whole test turns
# on BITMAP_WRITE_ERROR (bit 2) being present on disk at assemble; if the forge
# was a no-op (wrong sb offset from a stale loop cache, dd failure, in-tree md
# rewriting the super), the bitmap-alive + events-advanced PASS below is
# satisfied trivially without ever exercising the load-side mask -- a false PASS.
# dm/dd are already confirmed working, so a missing bit is a broken harness: FAIL
# loudly rather than skip, so the guard cannot silently stop covering the bug.
if [ $(( STATE_A_PLANTED & 4 )) -eq 0 ] || [ $(( STATE_B_PLANTED & 4 )) -eq 0 ]; then
	llbitmap_fail "bit-2 (WRITE_ERROR) forge did not land on disk (A=$STATE_A_PLANTED B=$STATE_B_PLANTED) -- cannot exercise the load-side mask"
fi

EVENTS_BEFORE=$(read_events "$LA")
echo "  sb->events before assemble: $EVENTS_BEFORE"

sudo dmesg --clear 2>/dev/null || true
# Releasing the members re-triggered udev auto-assembly into the in-tree md;
# stop it so our explicit assemble opens the members instead of failing with
# "is busy - skipping" (which would drop the array and misread as a disabled
# bitmap).
llbitmap_stop_inkernel_md "$LA" "$LB"
out=$(sudo "$MDADM" --assemble "$MS_DEV" "$LA" "$LB" --run 2>&1 || true)
echo "  assemble output: $out"
udevadm settle 2>/dev/null

# The array assembles either way (a disabled bitmap does not block the
# run); read the bitmap liveness directly from sysfs while it is up.
BITS_RAW="$(cat "/sys/block/$MS_NAME/${LLBITMAP_SYSFS_SUBDIR}/llbitmap/bits" 2>&1 || echo "READ_FAILED")"
echo "  --- llbitmap/bits ---"
echo "$BITS_RAW" | head -8

# Drive several md_update_sb cycles so a live bitmap advances sb->events.
for i in $(seq 1 4); do
	"$DD" if=/dev/urandom of="$MS_DEV" bs=1M count=1 seek=$((i*5)) \
		oflag=direct status=none 2>/dev/null || true
	sync
	echo idle | sudo tee "/sys/block/$MS_NAME/${LLBITMAP_SYSFS_SUBDIR}/sync_action" >/dev/null 2>&1 || true
	sleep 0.3
done
sync

sudo "$MDADM" --stop "$MS_DEV" >/dev/null 2>&1
udevadm settle 2>/dev/null

EVENTS_AFTER=$(read_events "$LA")
STATE_A_FINAL=$(read_state_byte0 "$LA")
echo "  sb->events after writes+stop: $EVENTS_AFTER (was $EVENTS_BEFORE)"
echo "  state byte0 final on A: $STATE_A_FINAL"

echo "  --- dmesg ---"
sudo dmesg | tail -20 | grep -iE "llbitmap|bitmap|raid1|fail|error" | head -10

# Bitmap is disabled (the bug) iff bits reports the io-error sentinel.
BITMAP_DISABLED=0
if echo "$BITS_RAW" | grep -qiE "bitmap io error|io error|READ_FAILED"; then
	BITMAP_DISABLED=1
fi

EVENTS_ADVANCED=0
[ "$EVENTS_AFTER" -gt "$EVENTS_BEFORE" ] && EVENTS_ADVANCED=1

echo
echo "=== verdict ==="
echo "  bitmap disabled (bits 'io error'): $BITMAP_DISABLED"
echo "  sb->events advanced ($EVENTS_BEFORE -> $EVENTS_AFTER): $EVENTS_ADVANCED"

if [ "$BITMAP_DISABLED" -eq 0 ] && [ "$EVENTS_ADVANCED" -eq 1 ]; then
	echo "PASS: llbitmap masks bit 2 on load -- bitmap alive, sb->events advancing"
	exit 0
elif [ "$BITMAP_DISABLED" -ne 0 ]; then
	echo "FAIL: bitmap disabled ('bitmap io error') -- load-side mask is missing"
	exit 1
else
	echo "FAIL: bitmap not flagged disabled but sb->events froze -- bitmap inert"
	exit 1
fi
