#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
# Mixed-error arm: legA completes data writes with BLK_STS_IOERR (a real
# device error) and legB with BLK_STS_TARGET (a p2p miss). The P2P
# override must win the master status: RC = -EINVAL. legB (rd1) must not
# be badblocked for a topology miss; legA MAY be badblocked or faulted —
# its error is real. UNFIXED base: badblocks absorb both errors and the
# master reports SUCCESS — silent loss with a half-written mirror.
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
trap 'p2p_cleanup; dmsetup remove legA 2>/dev/null; dmsetup remove legB 2>/dev/null; rmmod dm_errstat 2>/dev/null; rmmod brd 2>/dev/null' EXIT
p2p_load_ms_modules
modprobe brd rd_nr=2 rd_size=32768
insmod "$MODULES_DIR/dm_errstat.ko"
dmsetup create legA --table "0 $(blockdev --getsz /dev/ram0) errstat /dev/ram0 5"
dmsetup create legB --table "0 $(blockdev --getsz /dev/ram1) errstat /dev/ram1 121"
ARR="$(p2p_make_array 1 /dev/mapper/legA /dev/mapper/legB)"
dmsetup message legA 0 arm
dmsetup message legB 0 arm
RC="$(p2p_io write "$ARR" "$(p2p_bdf_by_serial cmb0)")"
dmsetup message legA 0 disarm
dmsetup message legB 0 disarm
[ "$RC" = "-22" ] || p2p_fail "mixed-error p2p write returned errno=$RC, want -22 (P2P override wins)"
BB="/sys/block/$(basename "$ARR")/$P2P_SYSFS/rd1/bad_blocks"
[ -e "$BB" ] || p2p_fail "bad_blocks sysfs missing at $BB"
[ -z "$(cat "$BB")" ] || p2p_fail "badblocks recorded on the p2p-miss leg rd1: $(cat "$BB")"
p2p_pass "mixed error: p2p miss won the master status, rd1 unblemished"
