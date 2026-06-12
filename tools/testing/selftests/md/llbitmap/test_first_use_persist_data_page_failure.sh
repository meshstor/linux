#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
#
# Reproducer for the init-time bitmap *data-page* write-failure gap fixed by
#   "md/llbitmap: detect init data-page write failure, commit super last".
#
# The earlier fix made llbitmap_init() persist the BITMAP_FIRST_USE-clear
# super synchronously with failure detection, but still flushed the bitmap
# *data* pages asynchronously (md_write_metadata()).  Before mddev->pers is
# assigned, super_written() -> md_error() is a no-op and md_super_wait() only
# waits for completion, so a data-page write error during --create was
# silently swallowed.  The super committed FIRST_USE-clear, so the next
# assemble skipped re-init and trusted stale/unwritten bitmap data.
#
# Unlike test_first_use_persist_failure.sh (which fails *every* write, a case
# both the old and fixed kernels reject), this test fails ONLY the bitmap data
# sectors while keeping the super sectors healthy -- the exact "super ok, data
# fails" window the fix closes:
#
#   - Old kernel: the super write (page 0, sectors 0-1) succeeds, so on-disk
#     FIRST_USE is cleared; the async data flush fails and is swallowed; the
#     array STARTS.  Bug.
#   - Fixed kernel: the data write is synchronous and failure-detected, and
#     the super (page 0) is committed last, so init returns -EIO with
#     FIRST_USE still set on disk; the array refuses to start.
#
# On-disk bitmap layout (metadata 1.2, 512-byte logical block => io_size 512):
#   bitmap super at SB; page 0 = [super: bytes 0..1023 = sectors 0..1]
#   [data: bytes 1024.. = sector 2..].  Chunk 0's init state lands at byte
#   1024, so failing sectors [SB+2, SB+8) reliably hits an init data write
#   while leaving the super (sectors SB..SB+1) writable.
#
# Mechanism:
#   1. Create a 2-member raid1 over two loop devices, init the bitmap.
#   2. Stop; plant BITMAP_FIRST_USE on both members so the next assemble
#      must re-run llbitmap_init.
#   3. Wrap each loop in a dm device: linear (healthy) for the super and
#      everything else, flakey/error_writes for the 6 page-0 data sectors.
#   4. mdadm --assemble over the dm devices.
#
# Verdict:
#   PASS  the fixed kernel refused: "failed to RUN_ARRAY ...: I/O error" OR
#         dmesg "failed to persist initial bitmap" OR FIRST_USE still set on
#         both members.
#   FAIL  the array started AND FIRST_USE was cleared while a data-page write
#         demonstrably failed -- the swallowed-error bug.
#   SKIP/INCONCLUSIVE  the injection did not engage (no write error observed),
#         so neither bug nor fix was exercised.

set -u

DIR="$(dirname "$0")"
. "$DIR/lib.sh"

llbitmap_require_root
llbitmap_require_modules
llbitmap_require_tools
command -v dmsetup >/dev/null || llbitmap_skip "dmsetup not available"
modprobe dm-flakey 2>/dev/null || true
dmsetup targets | grep -q '^flakey' || llbitmap_skip "dm-flakey target missing"

LOOP_SIZE_MB=100

DP_DM_NAMES=()
dp_cleanup() {
	set +e
	for n in "${DP_DM_NAMES[@]:-}"; do
		dmsetup remove "$n" 2>/dev/null
	done
	llbitmap_cleanup
	set -e
}
trap dp_cleanup EXIT

# Byte offset of the bitmap super within a member (sb_start + offset field).
bitmap_super_offset() {
	local dev="$1"
	local sb_start=4096
	local off
	off=$(dd if="$dev" bs=1 skip=$((sb_start + 96)) count=4 status=none |
	      od -An -tu4 -N4 | tr -d ' ')
	echo $(( sb_start + off * 512 ))
}

read_state_byte0() {
	local dev="$1" sb_off
	sb_off=$(bitmap_super_offset "$dev")
	dd if="$dev" bs=1 skip=$((sb_off + 48)) count=1 status=none | od -An -tu1 -N1 | tr -d ' '
}

write_state_byte0() {
	local dev="$1" val="$2" sb_off
	sb_off=$(bitmap_super_offset "$dev")
	printf "\\x$(printf '%02x' "$val")" | dd of="$dev" bs=1 seek=$((sb_off + 48)) count=1 conv=notrunc status=none
}

# Build the composite dm table: healthy linear everywhere except 6 error_writes
# sectors covering page-0 data (sectors SB_SECTOR+2 .. SB_SECTOR+7).
make_selective_table() {
	local loop="$1" sb_sector="$2" total="$3"
	local s2=$(( sb_sector + 2 ))
	local s8=$(( sb_sector + 8 ))
	printf '0 %d linear %s 0\n' "$s2" "$loop"
	printf '%d 6 flakey %s %d 0 999 1 error_writes\n' "$s2" "$loop" "$s2"
	printf '%d %d linear %s %d\n' "$s8" "$(( total - s8 ))" "$loop" "$s8"
}

# Setup
LA=$(llbitmap_make_loop $LOOP_SIZE_MB)
LB=$(llbitmap_make_loop $LOOP_SIZE_MB)

llbitmap_alloc_ms_dev >/dev/null
MS_DEV="$LLBITMAP_TEST_MS_DEV"
MS_NAME="$LLBITMAP_TEST_MS_NAME"

echo "=== FIRST_USE-persist data-page failure-detection reproducer ==="
echo "  members: $LA, $LB"
echo "  md dev: $MS_DEV"

"$MDADM" --create "$MS_DEV" \
	--level=1 --metadata=1.2 --raid-devices=2 --homehost=any \
	--bitmap=auto --assume-clean "$LA" "$LB" --run --force \
	>/dev/null 2>&1 || llbitmap_skip "mdadm create failed"

bt=$(cat "/sys/block/$MS_NAME/ms/bitmap_type" 2>/dev/null || echo "")
case "$bt" in
	*"[llbitmap]"*) : ;;
	*) llbitmap_skip "not llbitmap ($bt)" ;;
esac

sync
"$MDADM" --stop "$MS_DEV" >/dev/null 2>&1
udevadm settle 2>/dev/null

# Plant FIRST_USE (bit 3 = 0x08) on both members so re-init runs on assemble.
SA=$(read_state_byte0 "$LA"); SB_=$(read_state_byte0 "$LB")
write_state_byte0 "$LA" $(( SA | 8 ))
write_state_byte0 "$LB" $(( SB_ | 8 ))
sync
blockdev --flushbufs "$LA" 2>/dev/null || true
blockdev --flushbufs "$LB" 2>/dev/null || true
A_PLANTED=$(read_state_byte0 "$LA"); B_PLANTED=$(read_state_byte0 "$LB")
echo "  planted FIRST_USE: A=$A_PLANTED B=$B_PLANTED (expect 0x08 set)"
[ $(( A_PLANTED & 8 )) -ne 0 ] || llbitmap_skip "could not plant FIRST_USE on A"

# Compute the bitmap super sector and build the selective dm devices.
SB_BYTE=$(bitmap_super_offset "$LA")
SB_SECTOR=$(( SB_BYTE / 512 ))
SIZE_A=$(blockdev --getsz "$LA")
SIZE_B=$(blockdev --getsz "$LB")
echo "  bitmap super at byte $SB_BYTE (sector $SB_SECTOR); failing sectors $((SB_SECTOR+2))..$((SB_SECTOR+7))"

dmsetup create dp-selA --table "$(make_selective_table "$LA" "$SB_SECTOR" "$SIZE_A")"
DP_DM_NAMES+=("dp-selA")
dmsetup create dp-selB --table "$(make_selective_table "$LB" "$SB_SECTOR" "$SIZE_B")"
DP_DM_NAMES+=("dp-selB")
FA=/dev/mapper/dp-selA
FB=/dev/mapper/dp-selB

# Assemble. llbitmap_init runs (FIRST_USE on disk); the super sectors are
# healthy but the page-0 data sectors return EIO on write.
llbitmap_dmesg_clear
out=$("$MDADM" --assemble "$MS_DEV" "$FA" "$FB" --run 2>&1 || true)
echo "  assemble output: $out"

"$MDADM" --stop "$MS_DEV" >/dev/null 2>&1 || true
udevadm settle 2>/dev/null

echo "  --- relevant dmesg ---"
dmesg | tail -40 | grep -iE 'llbitmap|md/raid|persist|gets error|bitmap' | tail -10

# Read final on-disk FIRST_USE via the underlying loops (bypass dm).
dmsetup remove dp-selA 2>/dev/null; dmsetup remove dp-selB 2>/dev/null
DP_DM_NAMES=()
A_AFTER=$(read_state_byte0 "$LA"); B_AFTER=$(read_state_byte0 "$LB")
A_STILL=$(( A_AFTER & 8 )); B_STILL=$(( B_AFTER & 8 ))

echo
echo "=== verdict ==="
echo "  FIRST_USE after assemble: A=$A_STILL B=$B_STILL  (set => init did NOT commit)"
echo "  assemble output: $out"

# Did a bitmap write failure actually occur? Either the fix's detection
# message, or the old kernel's swallowed async super_written() error log.
INJECTION_HIT=0
if dmesg | tail -80 | grep -qiE 'failed to persist initial bitmap|gets error='; then
	INJECTION_HIT=1
fi

# Match only errno-agnostic refusal strings; a generic 'Invalid
# argument' alternative would let any unrelated mdadm EINVAL pass as
# proof the fix engaged.
FIX_SIGNAL=0
if echo "$out" | grep -qiE 'failed to RUN_ARRAY|started.*0 drives'; then
	FIX_SIGNAL=1
fi
if dmesg | tail -80 | grep -q 'failed to persist initial bitmap'; then
	FIX_SIGNAL=1
fi
if [ "$A_STILL" -ne 0 ] && [ "$B_STILL" -ne 0 ]; then
	FIX_SIGNAL=1
fi

if [ "$FIX_SIGNAL" -eq 1 ]; then
	llbitmap_pass "init detected the data-page write failure (refused / FIRST_USE preserved)"
fi

if [ "$A_STILL" -eq 0 ] && [ "$B_STILL" -eq 0 ] && [ "$INJECTION_HIT" -eq 1 ]; then
	llbitmap_fail "array started with FIRST_USE cleared despite a swallowed data-page write failure"
fi

llbitmap_skip "injection did not engage (no bitmap write error observed); test inconclusive"
