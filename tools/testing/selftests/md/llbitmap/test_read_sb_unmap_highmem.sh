#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
#
# Reproducer for the llbitmap read_sb cleanup-ordering fix:
#   "md/llbitmap: unmap bitmap super page before freeing".
#
# llbitmap_read_sb()'s out_put_page label is the single shared exit for
# both the success and every error path.  It used to call
#   __free_page(sb_page);
#   kunmap_local(sb);
# i.e. free the super page while it still holds a live kmap_local
# mapping.  Under CONFIG_DEBUG_HIGHMEM=y this trips a WARN in the page
# allocator's debug check; on 32-bit CONFIG_HIGHMEM it can leave a stale
# highmem mapping for the next allocator user.  The fix swaps the order
# (kunmap_local first).
#
# The reorder is observable ONLY under CONFIG_DEBUG_HIGHMEM (on a normal
# 64-bit kernel the two orders are indistinguishable), so this test SKIPs
# unless the running kernel was built with it.  That makes it a no-op on
# production hosts and a real regression guard on a DEBUG_HIGHMEM CI
# kernel.
#
# Method (DEBUG_HIGHMEM only):
#   1. Create an llbitmap raid1, then stop.
#   2. Forge a non-power-of-2 chunksize into the bitmap super (and clear
#      FIRST_USE) so the next assemble drives llbitmap_read_sb() down a
#      "goto out_put_page" error path -- exercising the reordered lines.
#   3. Clear dmesg, assemble (expected to fail the run).
#   4. Confirm the error path was actually reached (kernel logged
#      "chunksize not a power of 2"); if not, SKIP rather than risk a
#      false PASS that exercised nothing.
#   5. Inspect dmesg for a WARN/backtrace through llbitmap_read_sb.
#
# Verdict:
#   PASS  read_sb error path reached AND no llbitmap_read_sb WARN/splat.
#   FAIL  a WARN/backtrace names llbitmap_read_sb (or a highmem/kmap
#         debug splat fired) -- the free-before-unmap order regressed.
#   SKIP  not a DEBUG_HIGHMEM kernel, config undeterminable, or the
#         read_sb error path could not be engaged.

set -u

DIR="$(dirname "$0")"
. "$DIR/lib.sh"

llbitmap_require_root
llbitmap_require_modules
llbitmap_require_tools

config_has_y() {
	local opt="$1"
	if [ -r /proc/config.gz ] && command -v zcat >/dev/null 2>&1; then
		zcat /proc/config.gz 2>/dev/null | grep -q "^${opt}=y" && return 0
	fi
	if [ -r "/boot/config-$(uname -r)" ]; then
		grep -q "^${opt}=y" "/boot/config-$(uname -r)" 2>/dev/null && return 0
	fi
	if [ -r "/lib/modules/$(uname -r)/build/.config" ]; then
		grep -q "^${opt}=y" "/lib/modules/$(uname -r)/build/.config" 2>/dev/null && return 0
	fi
	return 1
}

config_readable() {
	[ -r /proc/config.gz ] || [ -r "/boot/config-$(uname -r)" ] || \
		[ -r "/lib/modules/$(uname -r)/build/.config" ]
}

config_readable || llbitmap_skip "kernel config not readable; cannot confirm CONFIG_DEBUG_HIGHMEM"
config_has_y CONFIG_DEBUG_HIGHMEM || \
	llbitmap_skip "CONFIG_DEBUG_HIGHMEM not set; unmap/free reorder is unobservable here"

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

# Clear FIRST_USE (bit 3) so read_sb proceeds to the chunksize check
# instead of diverting into llbitmap_init re-initialisation.
clear_first_use() {
	local dev="$1"
	local sb_off cur
	sb_off=$(bitmap_super_offset "$dev")
	cur=$(read_state_byte0 "$dev")
	printf "\\x$(printf '%02x' $((cur & ~8)))" |
		"$DD" of="$dev" bs=1 seek=$((sb_off + 48)) count=1 conv=notrunc status=none
}

# Forge a non-power-of-2 chunksize (=3) into the __le32 at sb+52.
forge_bad_chunksize() {
	local dev="$1"
	local sb_off
	sb_off=$(bitmap_super_offset "$dev")
	printf '\x03\x00\x00\x00' |
		"$DD" of="$dev" bs=1 seek=$((sb_off + 52)) count=4 conv=notrunc status=none
}

LA=$(llbitmap_make_loop $LOOP_SIZE_MB)
LB=$(llbitmap_make_loop $LOOP_SIZE_MB)
llbitmap_alloc_ms_dev >/dev/null
MS_DEV="$LLBITMAP_TEST_MS_DEV"
MS_NAME="$LLBITMAP_TEST_MS_NAME"

echo "=== llbitmap read_sb out_put_page unmap-ordering (DEBUG_HIGHMEM) ==="
echo "  members: $LA $LB  md: $MS_DEV"

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

for d in "$LA" "$LB"; do
	clear_first_use "$d"
	forge_bad_chunksize "$d"
done
sync
blockdev --flushbufs "$LA" 2>/dev/null || true
blockdev --flushbufs "$LB" 2>/dev/null || true
echo "  forged non-power-of-2 chunksize on both members"

sudo dmesg --clear 2>/dev/null || true
out=$(sudo "$MDADM" --assemble "$MS_DEV" "$LA" "$LB" --run 2>&1 || true)
echo "  assemble output: $out"
sudo "$MDADM" --stop "$MS_DEV" >/dev/null 2>&1 || true
udevadm settle 2>/dev/null

DM="$(sudo dmesg 2>/dev/null | tail -200)"
echo "  --- relevant dmesg ---"
echo "$DM" | grep -iE 'llbitmap|chunksize|WARNING|BUG|kmap|highmem|Call Trace' | head -20

# Confirm the read_sb error path was actually engaged.  pr_err uses the
# "md/llbitmap: <dev>: ..." format (no function name), so this string can
# only come from the chunksize check in llbitmap_read_sb().
ENGAGED=0
echo "$DM" | grep -q "chunksize not a power of 2" && ENGAGED=1

# A WARN/BUG splat resolves the offending frame to a symbol; the only way
# "llbitmap_read_sb" appears in the log is a backtrace through it.  Back
# that with generic highmem/kmap debug signatures.
WARN_FIRED=0
if echo "$DM" | grep -q 'llbitmap_read_sb'; then
	WARN_FIRED=1
fi
if echo "$DM" | grep -iE 'WARNING.*(highmem|kmap)|__kunmap_local|kunmap_local_indexed|BUG: .*kmap' >/dev/null; then
	WARN_FIRED=1
fi

echo
echo "=== verdict ==="
echo "  read_sb error path engaged: $ENGAGED"
echo "  llbitmap_read_sb WARN/splat: $WARN_FIRED"

if [ "$ENGAGED" -eq 0 ]; then
	llbitmap_skip "could not engage llbitmap_read_sb error path (no chunksize pr_err); nothing tested"
fi
if [ "$WARN_FIRED" -ne 0 ]; then
	echo "FAIL: WARN/backtrace through llbitmap_read_sb -- free-before-unmap order regressed"
	exit 1
fi
echo "PASS: read_sb error path clean under DEBUG_HIGHMEM (kunmap before free)"
exit 0
