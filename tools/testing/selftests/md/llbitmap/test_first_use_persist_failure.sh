#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
#
# Reproducer for the FIRST_USE-persist failure-detection fix:
#   "md/llbitmap: persist BITMAP_FIRST_USE clear during init with
#    fail-detect".
#
# llbitmap_init() persists the BITMAP_FIRST_USE clear before the bulk
# page flush.  The persist write itself can fail (hardware EIO).
# Without per-batch failure detection, llbitmap_init() reports success
# while on-disk BITMAP_FIRST_USE is still set; the next assemble
# re-runs llbitmap_init and clobbers sync state.
#
# This test simulates a persist-write failure via dm-flakey
# error_writes and verifies that the kernel refuses to start the
# array with -EIO instead of silently completing with stale
# FIRST_USE on disk.
#
# Mechanism:
#   1. Create a 2-member raid1 over two dm-flakey nodes (always up).
#   2. Stop the array.
#   3. Plant BITMAP_FIRST_USE (bit 3) in sb->state on both members
#      via direct dd to the underlying loop devices, simulating the
#      "crash before first md_update_sb" state where the next
#      assemble must re-run llbitmap_init.
#   4. Switch both flakey targets to "0 0 999 1 error_writes": every
#      write returns -EIO.  (The dm-flakey default down-interval
#      behavior is drop_writes -- silent success without persisting --
#      which is undetectable by any bi_status-based mechanism and has
#      no real-hardware equivalent; error_writes simulates the actual
#      fault mode the production fix is designed to catch.)
#   5. mdadm --assemble.  The kernel runs llbitmap_init, attempts to
#      persist the freshly initialised bitmap, every rdev write fails.
#      The fix's synchronous sync_page_io() writes detect the total
#      (all-rdev) failure, BITMAP_WRITE_ERROR is set, and llbitmap_init()
#      returns -EIO; RUN_ARRAY fails.
#
# Verdict:
#   PASS  mdadm reports "failed to RUN_ARRAY ...: Input/output error"
#         OR dmesg shows "failed to persist initial bitmap".
#   FAIL  mdadm reports "started with 2 drives" while on-disk
#         FIRST_USE survived (the fix is missing).

set -u

DIR="$(dirname "$0")"
. "$DIR/lib.sh"

llbitmap_require_root
llbitmap_require_modules
llbitmap_require_tools
command -v dmsetup >/dev/null || llbitmap_skip "dmsetup not available"
sudo modprobe dm-flakey 2>/dev/null || true
sudo dmsetup targets | grep -q '^flakey' || llbitmap_skip "dm-flakey target missing"

LOOP_SIZE_MB=100

P12_FLAKEY_NAMES=()
p12_cleanup() {
	set +e
	for n in "${P12_FLAKEY_NAMES[@]:-}"; do
		sudo dmsetup remove "$n" 2>/dev/null
	done
	llbitmap_cleanup
	set -e
}
trap p12_cleanup EXIT

bitmap_super_offset() {
	local dev="$1"
	local sb_start=4096
	local off
	off=$(dd if="$dev" bs=1 skip=$((sb_start + 96)) count=4 status=none |
	      od -An -tu4 -N4 | tr -d ' ')
	echo $(( sb_start + off * 512 ))
}

read_state_byte0() {
	local dev="$1"
	local sb_off
	sb_off=$(bitmap_super_offset "$dev")
	dd if="$dev" bs=1 skip=$((sb_off + 48)) count=1 status=none | od -An -tu1 -N1 | tr -d ' '
}

write_state_byte0() {
	# Write a single byte at sb->state byte 0 (low byte; FIRST_USE = bit 3 = 0x08)
	local dev="$1"
	local val="$2"
	local sb_off
	sb_off=$(bitmap_super_offset "$dev")
	printf "\\x$(printf '%02x' "$val")" | dd of="$dev" bs=1 seek=$((sb_off + 48)) count=1 conv=notrunc status=none
}

# Setup
LA=$(llbitmap_make_loop $LOOP_SIZE_MB)
LB=$(llbitmap_make_loop $LOOP_SIZE_MB)

SIZE_A=$(blockdev --getsz "$LA")
SIZE_B=$(blockdev --getsz "$LB")
sudo dmsetup create p12-flakeyA --table "0 $SIZE_A flakey $LA 0 999 0"
P12_FLAKEY_NAMES+=("p12-flakeyA")
sudo dmsetup create p12-flakeyB --table "0 $SIZE_B flakey $LB 0 999 0"
P12_FLAKEY_NAMES+=("p12-flakeyB")

FA=/dev/mapper/p12-flakeyA
FB=/dev/mapper/p12-flakeyB

llbitmap_alloc_ms_dev >/dev/null
MS_DEV="$LLBITMAP_TEST_MS_DEV"
MS_NAME="$LLBITMAP_TEST_MS_NAME"

echo "=== FIRST_USE-persist failure-detection reproducer ==="
echo "  members: $FA ($LA), $FB ($LB)"
echo "  md dev: $MS_DEV"

"$MDADM" --create "$MS_DEV" \
	--level=1 --metadata=1.2 --raid-devices=2 --homehost=any \
	--bitmap=auto --assume-clean "$FA" "$FB" --run --force \
	>/dev/null 2>&1 || llbitmap_skip "mdadm create failed"

bt=$(cat "/sys/block/$MS_NAME/ms/bitmap_type" 2>/dev/null || echo "")
case "$bt" in
	*"[llbitmap]"*) : ;;
	*) llbitmap_skip "not llbitmap ($bt)" ;;
esac

# Force one md_update_sb so FIRST_USE gets cleared via the normal path,
# then we'll set it back manually to simulate the "crash before first
# md_update_sb after create" scenario.
sync
sudo "$MDADM" --stop "$MS_DEV" >/dev/null 2>&1
udevadm settle 2>/dev/null

# Read state from both underlying loops (NOT via dm-flakey, so we read
# what's actually on disk regardless of flakey state)
STATE_A_BEFORE=$(read_state_byte0 "$LA")
STATE_B_BEFORE=$(read_state_byte0 "$LB")
echo "  state byte0 after create+stop: A=$STATE_A_BEFORE  B=$STATE_B_BEFORE"

# Plant FIRST_USE (bit 3 = 0x08) on both members. Preserve whatever was there.
NEW_A=$((STATE_A_BEFORE | 8))
NEW_B=$((STATE_B_BEFORE | 8))
write_state_byte0 "$LA" "$NEW_A"
write_state_byte0 "$LB" "$NEW_B"
sync
blockdev --flushbufs "$LA" 2>/dev/null || true
blockdev --flushbufs "$LB" 2>/dev/null || true
STATE_A_PLANTED=$(read_state_byte0 "$LA")
STATE_B_PLANTED=$(read_state_byte0 "$LB")
echo "  state byte0 after planting FIRST_USE: A=$STATE_A_PLANTED  B=$STATE_B_PLANTED (expect bit 0x08 set)"

# Switch BOTH flakeys to always-down
sudo dmsetup suspend p12-flakeyA
sudo dmsetup suspend p12-flakeyB
# error_writes feature: writes return EIO (default down-interval behavior
# is drop_writes which silently returns success without persisting; that
# scenario is undetectable by any bi_status-based mechanism, so the test
# explicitly requests EIO).
sudo dmsetup load p12-flakeyA --table "0 $SIZE_A flakey $LA 0 0 999 1 error_writes"
sudo dmsetup load p12-flakeyB --table "0 $SIZE_B flakey $LB 0 0 999 1 error_writes"
sudo dmsetup resume p12-flakeyA
sudo dmsetup resume p12-flakeyB
echo "  flakey: all writes will return EIO"

# Attempt assemble. llbitmap_init must run because FIRST_USE is on disk.
# Inside llbitmap_init it calls llbitmap_refresh_sb then
# llbitmap_init_flush_sync, which writes every page to both rdevs (all fail).
sudo dmesg --clear 2>/dev/null || true
out=$(sudo "$MDADM" --assemble "$MS_DEV" "$FA" "$FB" --run 2>&1 || true)
echo "  assemble output: $out"

# Stop whatever is up (the array may or may not have started)
sudo "$MDADM" --stop "$MS_DEV" >/dev/null 2>&1 || true
udevadm settle 2>/dev/null

# Diagnostic dmesg
echo "  --- relevant dmesg ---"
sudo dmesg | tail -30 | grep -iE 'llbitmap|md/raid|MS|MD_BROKEN|fail|broken' | head -10

# Switch flakeys back up to read final disk state
sudo dmsetup suspend p12-flakeyA
sudo dmsetup suspend p12-flakeyB
sudo dmsetup load p12-flakeyA --table "0 $SIZE_A flakey $LA 0 999 0"
sudo dmsetup load p12-flakeyB --table "0 $SIZE_B flakey $LB 0 999 0"
sudo dmsetup resume p12-flakeyA
sudo dmsetup resume p12-flakeyB

STATE_A_AFTER=$(read_state_byte0 "$LA")
STATE_B_AFTER=$(read_state_byte0 "$LB")
echo "  state byte0 after assemble cycle: A=$STATE_A_AFTER  B=$STATE_B_AFTER"

A_HAD_FIRST=$(( STATE_A_PLANTED & 8 ))
B_HAD_FIRST=$(( STATE_B_PLANTED & 8 ))
A_STILL=$(( STATE_A_AFTER & 8 ))
B_STILL=$(( STATE_B_AFTER & 8 ))

echo
echo "=== verdict ==="
echo "  FIRST_USE planted on A: $A_HAD_FIRST  still set after: $A_STILL"
echo "  FIRST_USE planted on B: $B_HAD_FIRST  still set after: $B_STILL"
echo "  assemble output: $out"

# Fix is in place when EITHER mdadm refused to start the array
# OR dmesg shows the "failed to persist initial bitmap" message.
# The on-disk FIRST_USE may still be set (writes failed; that's why
# the fix returned -EIO) but the caller now knows the persist failed.
# Match only errno-agnostic refusal strings: a generic 'Invalid
# argument' alternative would let any unrelated mdadm EINVAL pass as
# proof the fix engaged.
FIX_SIGNAL=0
if echo "$out" | grep -qiE 'failed to RUN_ARRAY|started.*0 drives'; then
	FIX_SIGNAL=1
fi
if sudo dmesg | tail -50 | grep -q 'failed to persist initial bitmap'; then
	FIX_SIGNAL=1
fi

if [ "$FIX_SIGNAL" -eq 1 ]; then
	echo "PASS: fix signal observed (assemble refused OR persist-failure dmesg)"
	exit 0
fi

if [ "$A_STILL" -ne 0 ] || [ "$B_STILL" -ne 0 ]; then
	echo "FAIL: bug present — assemble reported success while FIRST_USE survived"
	echo "  Need synchronous sync_page_io()-based total-write-failure detection"
	echo "  + -EIO return from llbitmap_init"
	exit 1
fi

echo "INCONCLUSIVE: FIRST_USE cleared and no fix signal — neither bug nor fix observed"
exit 1
