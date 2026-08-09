#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
# TARGET-era arm: legB completes data writes with BLK_STS_TARGET (what
# <=6.16 nvme-pci and fabrics paths return for an unreachable P2P map).
# The p2p pages come from the CMB; the members are brd + dm-errstat, so
# this runs the md arm without real nvme reachability in play.
# UNFIXED base: TARGET is handled as a real write error -> badblocks
# recorded on a healthy leg AND the master write "succeeds" via legA.
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
if [ -z "${P2P_IN_VM:-}" ]; then
	exec "$DIR/run_vm.sh" symmetric \
		env P2P_IN_VM=1 MS_MOD_DIR="${MS_MOD_DIR:-}" \
		MDADM="${MDADM:-}" MD_SUBSYS="${MD_SUBSYS:-}" \
		"$DIR/$(basename "$0")"
fi
. "$DIR/lib.sh"
p2p_require_root; p2p_require_rig
trap 'p2p_cleanup; dmsetup remove legB 2>/dev/null; rmmod dm_errstat 2>/dev/null; rmmod brd 2>/dev/null' EXIT
p2p_load_ms_modules
modprobe brd rd_nr=2 rd_size=32768
insmod "$MODULES_DIR/dm_errstat.ko"
dmsetup create legB --table "0 $(blockdev --getsz /dev/ram1) errstat /dev/ram1 121"
ARR="$(p2p_make_array 1 /dev/ram0 /dev/mapper/legB)"
dmsetup message legB 0 arm
RC="$(p2p_io write "$ARR" "$(p2p_bdf_by_serial cmb0)")"
dmsetup message legB 0 disarm
[ "$RC" = "-22" ] || p2p_fail "TARGET-status p2p write returned errno=$RC, want -22"
p2p_member_state "$ARR" | grep -q "Failed Devices : 0" \
	|| p2p_fail "healthy member faulted on TARGET p2p status"
for bb in /sys/block/$(basename "$ARR")/$P2P_SYSFS/rd*/bad_blocks; do
	[ -e "$bb" ] || p2p_fail "bad_blocks sysfs missing at $bb"
	[ -z "$(cat "$bb")" ] || p2p_fail "badblocks recorded at $bb: $(cat "$bb")"
done
p2p_pass "TARGET-status p2p write failed loud, no badblocks, no fault"
