#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
#
# Regression test: data written while a lockless-bitmap RAID 10 array is
# degraded must be recovered onto a member that is later rebuilt.
#
# Two heal paths, two historic bugs:
#
#   add    -- rebuild onto a brand-new blank spare.  md_do_sync() offered
#             per-DEVICE recovery offsets to llbitmap_skip_sync_blocks(),
#             which indexes chunks by ARRAY sector; for raid10 the spaces
#             differ, the misread chunks were Unwritten, and the whole
#             rebuild was skipped ("md: only consult skip_sync_blocks
#             when 'j' is in the bitmap's domain").
#   re-add -- bitmap catch-up of the old member.  llbitmap freezes Dirty
#             bits while degraded so catch-up knows what the absent
#             member missed, but llbitmap_start_sync() reported only
#             NeedSync chunks as must-sync, skipping every degraded-era
#             write ("md/llbitmap: recover Dirty chunks when rebuilding
#             a member").
#
# Either way the array reported optimal while the rebuilt member held
# stale data -- noticed only when its mirror partner failed too.
#
# Both bugs are exercised across two geometries, because the first fix
# initially gated the md_do_sync() consult on the size coincidence
# resync_max_sectors == dev_sectors, which holds exactly when
# raid_disks == near_copies * far_copies:
#
#   n2 (near=2, 4 disks)  -- sizes differ, consult gated off.
#   f2 (far=2, 2 disks)   -- sizes match by coincidence yet
#             raid10_find_virt(j) != j everywhere (device chunk c on
#             disk d holds array chunk 2c+d), so the consult kept
#             serving wrong-domain answers and rebuilds were still
#             skipped ("md: gate skip_sync_blocks on an explicit
#             personality capability").
#
# Oracle: after healing, fail the surviving holder of the region's other
# copy so the region's affected chunks can only be served by the rebuilt
# member, then read the region back through the array and compare with
# what was written while degraded.
#
# Region placement (see layout_params): for n2 the region sits past one
# member's device span (array upper half) so the device-vs-array offset
# confusion cannot be masked.  For f2 the region sits in the array's
# second quarter: the wrong-domain consult reads chunk j for device
# offset j, i.e. chunks [SEEK/2, (SEEK+REGION)/2) -- placing the region
# at [SEEK, SEEK+REGION) keeps those misread chunks below the written
# region, hence Unwritten, hence "skip" on a broken kernel.
#
# LLBITMAP_HEAL selects the path(s):  add | re-add | both  (default both).
# LLBITMAP_LAYOUTS selects the geometries (default "n2 f2").
#
# Verdict:
#   PASS  degraded-era writes present on the rebuilt member (each path)
#   FAIL  rebuilt member serves stale data, or the rebuild never finishes
#   SKIP  environment prerequisites missing

set -u

DIR="$(dirname "$0")"
. "$DIR/lib.sh"

llbitmap_require_root
llbitmap_require_modules
llbitmap_require_tools

if ! head -1 ${LLBITMAP_PROC_STAT} 2>/dev/null | grep -qw raid10; then
	llbitmap_skip "raid10 personality not registered in ${LLBITMAP_PROC_STAT}"
fi

HEAL_MODE="${LLBITMAP_HEAL:-both}"
LAYOUTS="${LLBITMAP_LAYOUTS:-n2 f2}"
MEMBER_MB=512
REGION_MB=128

# layout_params n2|f2 -> NDEV, SEEK_MB, FAIL_IDX, PARTNER_IDX
#   NDEV         members used (MEMBERS[0..NDEV-1])
#   SEEK_MB      region offset; placement rationale in the header
#   FAIL_IDX     member degraded and later healed
#   PARTNER_IDX  surviving holder of the region's other copy, failed at
#                verify time so reads can only hit the healed member
layout_params() {
	case "$1" in
	n2)	NDEV=4; SEEK_MB=512; FAIL_IDX=3; PARTNER_IDX=2 ;;
	f2)	NDEV=2; SEEK_MB=256; FAIL_IDX=1; PARTNER_IDX=0 ;;
	*)	llbitmap_skip "unknown layout '$1'" ;;
	esac
}

# llbitmap_make_loop registers loop+file for cleanup only when called in
# the current shell; re-register after command substitution.
make_loop_reg() {
	REPLY="$(llbitmap_make_loop "$1")"
	LLBITMAP_TEST_LOOPS+=("$REPLY")
	LLBITMAP_TEST_FILES+=("$(losetup -nO BACK-FILE "$REPLY" | tr -d ' ')")
}

llbitmap_alloc_ms_dev >/dev/null
MS_DEV="$LLBITMAP_TEST_MS_DEV"
MS_NAME="$LLBITMAP_TEST_MS_NAME"
SYS="/sys/block/$MS_NAME/${LLBITMAP_SYSFS_SUBDIR}"

MEMBERS=()
for i in 0 1 2 3; do
	make_loop_reg "$MEMBER_MB"; MEMBERS+=("$REPLY")
done
make_loop_reg "$MEMBER_MB"; SPARE="$REPLY"

P2="$(mktemp "${TMPDIR:-/tmp}/llbitmap-selftest.P2.XXXXXX.img")"
LLBITMAP_TEST_FILES+=("$P2")

wait_idle_optimal() {
	local i
	for i in $(seq 1 240); do
		[ "$(cat "$SYS/sync_action" 2>/dev/null)" = "idle" ] &&
			[ "$(cat "$SYS/degraded" 2>/dev/null)" = "0" ] && return 0
		sleep 0.5
	done
	return 1
}

# run_case n2|f2 add|re-add -> exits via llbitmap_fail on data loss
run_case() {
	local layout="$1" heal="$2" i
	local NDEV SEEK_MB FAIL_IDX PARTNER_IDX

	layout_params "$layout"

	"$MDADM" --stop "$MS_DEV" >/dev/null 2>&1 || true
	for i in "${MEMBERS[@]}" "$SPARE"; do
		"$MDADM" --zero-superblock "$i" >/dev/null 2>&1 || true
	done

	"$MDADM" --create "$MS_DEV" --level=10 --layout="$layout" \
		--metadata=1.2 --raid-devices="$NDEV" --bitmap=lockless \
		--homehost=any "${MEMBERS[@]:0:$NDEV}" --run --force \
		>/dev/null 2>&1 \
		|| llbitmap_skip "mdadm create failed ($layout)"

	case "$(cat "$SYS/bitmap_type" 2>/dev/null || echo '')" in
	*"[llbitmap]"*) : ;;
	*) llbitmap_skip "expected llbitmap, got '$(cat "$SYS/bitmap_type" 2>/dev/null)'" ;;
	esac

	echo 2000000 > "$SYS/sync_speed_min"
	echo 2000000 > "$SYS/sync_speed_max"
	wait_idle_optimal || llbitmap_fail "$layout/$heal: initial sync never finished"

	# healthy-era pattern P1, then degrade, then degraded-era pattern P2
	"$DD" if=/dev/urandom of="$MS_DEV" bs=1M count="$REGION_MB" \
		seek="$SEEK_MB" oflag=direct status=none
	"$MDADM" "$MS_DEV" --fail "${MEMBERS[$FAIL_IDX]}" >/dev/null 2>&1
	"$MDADM" "$MS_DEV" --remove "${MEMBERS[$FAIL_IDX]}" >/dev/null 2>&1
	"$DD" if=/dev/urandom of="$P2" bs=1M count="$REGION_MB" status=none
	"$DD" if="$P2" of="$MS_DEV" bs=1M seek="$SEEK_MB" oflag=direct status=none

	case "$heal" in
	add)
		"$MDADM" "$MS_DEV" --add "$SPARE" >/dev/null 2>&1
		;;
	re-add)
		"$MDADM" "$MS_DEV" --re-add "${MEMBERS[$FAIL_IDX]}" >/dev/null 2>&1 ||
			llbitmap_fail "$layout/re-add: mdadm refused the old member"
		;;
	esac
	wait_idle_optimal || llbitmap_fail "$layout/$heal: rebuild never reached optimal"

	# force reads of the region's affected chunks onto the rebuilt member
	"$MDADM" "$MS_DEV" --fail "${MEMBERS[$PARTNER_IDX]}" >/dev/null 2>&1
	sleep 1

	if ! cmp -s <("$DD" if="$MS_DEV" bs=1M skip="$SEEK_MB" count="$REGION_MB" \
			iflag=direct status=none) "$P2"; then
		llbitmap_fail "$layout/$heal: rebuilt member serves stale data"
	fi
	echo "  ok: $layout/$heal heal keeps degraded-era writes"
}

case "$HEAL_MODE" in
add|re-add)	HEALS="$HEAL_MODE" ;;
both)		HEALS="add re-add" ;;
*)		llbitmap_skip "unknown LLBITMAP_HEAL=$HEAL_MODE" ;;
esac

echo "=== llbitmap raid10 degraded-write recovery ($LAYOUTS / $HEAL_MODE) ==="
for layout in $LAYOUTS; do
	for heal in $HEALS; do
		run_case "$layout" "$heal"
	done
done

llbitmap_pass "degraded-era writes present on rebuilt member ($LAYOUTS / $HEAL_MODE)"
