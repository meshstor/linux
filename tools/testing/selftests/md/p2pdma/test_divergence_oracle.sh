#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
# THE central test: the one the whole design exists to satisfy -- that a
# mirror never silently diverges. Write a known pattern through a leg
# that is P2P-unroutable (synthetic, via dm-errstat: deterministic and
# fully under our control, unlike real PCIe topology -- see
# test_topology_*.sh for that arm with a looser, mechanism-agnostic
# check). Read BOTH legs' raw bytes directly, bypassing md entirely.
#
# Pass = the legs are byte-identical, OR the only place they differ is
# EXACTLY the range md itself recorded as badblocked on the failing leg.
# Any other outcome -- legs differ outside the recorded range, or differ
# with nothing recorded at all -- is the silent-divergence bug this
# design exists to prevent.
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/lib.sh"
if [ -z "${P2P_IN_VM:-}" ]; then
	p2p_require_rig
	exec "$DIR/run_vm.sh" symmetric \
		env P2P_IN_VM=1 MS_MOD_DIR="${MS_MOD_DIR:-}" \
		MDADM="${MDADM:-}" MD_SUBSYS="${MD_SUBSYS:-}" \
		"$DIR/$(basename "$0")"
fi
p2p_require_root; p2p_require_rig
trap 'p2p_cleanup; dmsetup remove legB 2>/dev/null; rmmod dm_errstat 2>/dev/null; rmmod brd 2>/dev/null' EXIT
p2p_load_ms_modules
modprobe brd rd_nr=2 rd_size=65536
p2p_load_dm_errstat
dmsetup create legB --table "0 $(blockdev --getsz /dev/ram1) errstat /dev/ram1 p2pdma"
ARR="$(p2p_make_array 1 /dev/ram0 /dev/mapper/legB)"
FILL=a5
NSEC=16   # md_p2p_test's default kib=8 -> 16 sectors

dmsetup message legB 0 arm
RC="$(p2p_io write "$ARR" "$(p2p_bdf_by_serial cmb0)" fill=0x$FILL)"
dmsetup message legB 0 disarm
[ "$RC" = "0" ] || p2p_fail "write returned errno=$RC, want 0 (v6: succeeds off legA)"

OFFA="$(p2p_data_offset_sectors /dev/ram0)"
OFFB="$(p2p_data_offset_sectors /dev/mapper/legB)"
[ -n "$OFFA" ] || p2p_fail "could not resolve Data Offset for legA"
[ -n "$OFFB" ] || p2p_fail "could not resolve Data Offset for legB"

RDB="$(p2p_rd_dir_for_dev "$ARR" /dev/mapper/legB)" || p2p_fail "cannot find legB's rdev sysfs dir"
BBB="$RDB/bad_blocks"

p2p_raw_all_byte /dev/ram0 "$OFFA" "$NSEC" "$FILL" \
	|| p2p_fail "legA (the surviving leg) does not have the written pattern"

if p2p_raw_all_byte /dev/mapper/legB "$OFFB" "$NSEC" "$FILL"; then
	echo "note: legB also has the pattern -- injector letting the array-level write through is fine (legs identical)"
	p2p_bb_nonempty "$BBB" && p2p_fail "legB has the correct data yet also has a badblock recorded (inconsistent)"
else
	# legB genuinely diverges from legA: that divergence MUST be exactly
	# accounted for by a badblock covering this write's range.
	p2p_bb_nonempty "$BBB" \
		|| p2p_fail "SILENT DIVERGENCE: legB differs from legA and has NO badblock recorded"
	p2p_bb_covers "$BBB" "$OFFB" "$NSEC" \
		|| p2p_fail "legB differs from legA but its badblocks ($(cat "$BBB")) do not cover the written range [$OFFB, $((OFFB + NSEC)))"
	echo "note: legB diverges from legA exactly within the recorded badblock range -- fenced, not silent"
fi

p2p_pass "divergence oracle: legs identical, or divergence exactly bounded by a recorded badblock"
