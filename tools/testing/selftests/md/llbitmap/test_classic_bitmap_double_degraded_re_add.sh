#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
#
# Regression test: a classic-bitmap (--bitmap=internal) RAID 10 must not
# destroy the write-intent record of an absent member while rebuilding a
# *different* member.
#
# raid10_sync_request()'s recovery arm computes still_degraded -- "will
# the array still be degraded after this recovery completes?" -- and
# passes it to md_bitmap_start_sync(), whose !degraded branch consumes
# the chunk's NEEDED marker (the write-intent record).  The
# bitmap_operations conversion ("md/md-bitmap: merge
# md_bitmap_start_sync() into bitmap_operations") turned the loop's only
# assignment from still_degraded = 1 into = false, so the flag is
# constant false and every rebuild consumes NEEDED even when another
# member is still missing.  The same commit converted raid1 and raid5
# to "= true" correctly; only raid10 was inverted.
#
# Sequence (4-disk n2, mirror pairs {0,1} and {2,3}):
#
#   1. healthy-era pattern P1 over a region, full redundancy
#   2. fail+remove member 3 (D); write degraded-era pattern P2 over the
#      region -- bitmap records the intent D missed
#   3. fail+remove member 1 (B); --add a blank spare; wait for its
#      rebuild.  A fresh spare sets conf->fullsync, so the rebuild
#      walks every chunk and -- on a broken kernel -- start_sync(...,
#      false) strips NEEDED from all of them, including chunks whose
#      only unsatisfied intent belonged to D
#   4. --re-add D.  Bitmap catch-up consults the (now empty) intent
#      record and completes instantly, leaving D stale
#   5. fail member 2 (C, the surviving holder of the region's other
#      copy) so the region's odd chunks can only be served by D; read
#      the region back through the array and compare with P2
#
# This is the classic-bitmap sibling of the llbitmap scenario in
# test_recovery_degraded_writes.sh; it lives here to reuse lib.sh (the
# llbitmap_ helper prefix is historical, the helpers are bitmap-agnostic).
#
# Verdict:
#   PASS  degraded-era writes present on the re-added member
#   FAIL  intent record destroyed by the unrelated rebuild, or the
#         re-added member serves stale data
#   SKIP  environment prerequisites missing

set -u

DIR="$(dirname "$0")"
. "$DIR/lib.sh"

llbitmap_require_root
llbitmap_require_modules
llbitmap_require_tools

if ! head -1 /proc/msstat 2>/dev/null | grep -qw raid10; then
	llbitmap_skip "raid10 personality not registered in /proc/msstat"
fi

MEMBER_MB=512
REGION_MB=128
SEEK_MB=256
# member roles: 0=A (survivor), 1=B (rebuilt onto spare), 2=C (partner
# failed at verify time), 3=D (absent while P2 is written, re-added last)
B_IDX=1
C_IDX=2
D_IDX=3

make_loop_reg() {
	REPLY="$(llbitmap_make_loop "$1")"
	LLBITMAP_TEST_LOOPS+=("$REPLY")
	LLBITMAP_TEST_FILES+=("$(losetup -nO BACK-FILE "$REPLY" | tr -d ' ')")
}

llbitmap_alloc_ms_dev >/dev/null
MS_DEV="$LLBITMAP_TEST_MS_DEV"
MS_NAME="$LLBITMAP_TEST_MS_NAME"
SYS="/sys/block/$MS_NAME/ms"

MEMBERS=()
for i in 0 1 2 3; do
	make_loop_reg "$MEMBER_MB"; MEMBERS+=("$REPLY")
done
make_loop_reg "$MEMBER_MB"; SPARE="$REPLY"

P2="$(mktemp "${TMPDIR:-/tmp}/llbitmap-selftest.P2.XXXXXX.img")"
LLBITMAP_TEST_FILES+=("$P2")

# wait_idle_degraded N -> sync_action idle with exactly N missing members.
# degraded counts !In_sync members, so it cannot read N before the
# rebuild that reduces it to N has actually completed.
wait_idle_degraded() {
	local want="$1" i
	for i in $(seq 1 240); do
		[ "$(cat "$SYS/sync_action" 2>/dev/null)" = "idle" ] &&
			[ "$(cat "$SYS/degraded" 2>/dev/null)" = "$want" ] && return 0
		sleep 0.5
	done
	return 1
}

# bitmap_dirty_count MEMBER -> on-disk dirty chunk count via mdadm -X
bitmap_dirty_count() {
	"$MDADM" -X "$1" 2>/dev/null |
		awk -F'[(,]' '/Bitmap :/{gsub(/[^0-9]/, "", $3); print $3; exit}'
}

echo "=== classic-bitmap raid10 double-degraded re-add ==="

"$MDADM" --create "$MS_DEV" --level=10 --layout=n2 --metadata=1.2 \
	--raid-devices=4 --bitmap=internal --delay=1 --homehost=any \
	"${MEMBERS[@]}" --run --force >/dev/null 2>&1 \
	|| llbitmap_skip "mdadm create failed"

case "$(cat "$SYS/bitmap_type" 2>/dev/null || echo '')" in
*"[bitmap]"*) : ;;
*) llbitmap_skip "expected classic bitmap, got '$(cat "$SYS/bitmap_type" 2>/dev/null)'" ;;
esac

echo 2000000 > "$SYS/sync_speed_min"
echo 2000000 > "$SYS/sync_speed_max"
wait_idle_degraded 0 || llbitmap_fail "initial sync never finished"

# healthy-era pattern, then lose D, then degraded-era pattern P2
dd if=/dev/urandom of="$MS_DEV" bs=1M count="$REGION_MB" \
	seek="$SEEK_MB" oflag=direct status=none
"$MDADM" "$MS_DEV" --fail "${MEMBERS[$D_IDX]}" >/dev/null 2>&1
"$MDADM" "$MS_DEV" --remove "${MEMBERS[$D_IDX]}" >/dev/null 2>&1
dd if=/dev/urandom of="$P2" bs=1M count="$REGION_MB" status=none
dd if="$P2" of="$MS_DEV" bs=1M seek="$SEEK_MB" oflag=direct status=none

# lose B as well, rebuild a blank spare into its slot (slot 1 is the
# first free slot, so the spare lands there, not in D's)
"$MDADM" "$MS_DEV" --fail "${MEMBERS[$B_IDX]}" >/dev/null 2>&1
"$MDADM" "$MS_DEV" --remove "${MEMBERS[$B_IDX]}" >/dev/null 2>&1
"$MDADM" "$MS_DEV" --add "$SPARE" >/dev/null 2>&1
wait_idle_degraded 1 || llbitmap_fail "spare rebuild never finished"

# the rebuild restored B's slot only; D's intent record must survive it.
# --delay=1 above makes the daemon's lazy on-disk clearing fast enough
# to observe: two daemon passes, so 5s is comfortably past it.
sleep 5
DIRTY="$(bitmap_dirty_count "${MEMBERS[0]}")"
echo "  on-disk dirty chunks after unrelated rebuild: ${DIRTY:-unreadable}"
if [ "${DIRTY:-0}" -eq 0 ]; then
	llbitmap_fail "write-intent record for the absent member was destroyed by an unrelated rebuild"
fi

"$MDADM" "$MS_DEV" --re-add "${MEMBERS[$D_IDX]}" >/dev/null 2>&1 ||
	llbitmap_fail "mdadm refused to re-add the old member"
wait_idle_degraded 0 || llbitmap_fail "re-add catch-up never finished"

# force reads of the region's affected chunks onto the re-added member
"$MDADM" "$MS_DEV" --fail "${MEMBERS[$C_IDX]}" >/dev/null 2>&1
sleep 1

if ! cmp -s <(dd if="$MS_DEV" bs=1M skip="$SEEK_MB" count="$REGION_MB" \
		iflag=direct status=none) "$P2"; then
	llbitmap_fail "re-added member serves stale data"
fi

llbitmap_pass "degraded-era writes survive an unrelated member rebuild"
