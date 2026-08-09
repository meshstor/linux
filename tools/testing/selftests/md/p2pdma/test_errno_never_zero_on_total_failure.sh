#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
# The "outbound clamp" regression guard (dkms/compat/compat.h's DANGER
# note): the raw BLK_STS_P2PDMA value (18) must never escape md, because
# on a kernel with no native definition, blk_status_to_errno(18) is 0 --
# if that raw value ever leaked onto a bio a caller sees, a genuinely
# failed I/O would look like a successful completion.
#
# Both legs are synthetically forced to literal BLK_STS_P2PDMA (via
# dm-errstat) so EVERY leg fails on the same write -- guaranteeing the
# "total failure" case (no leg contributes R1BIO_Uptodate) rather than
# hoping to observe it. Uses an ordinary application-level pwrite
# (xfs_io -d, O_DIRECT) as the most realistic stand-in for "a normal
# process doing I/O"; a true io_uring completion isn't practical to
# drive from a shell test, but the invariant under test -- the
# completion status a caller observes -- is the same regardless of the
# submission API.
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
p2p_require_tool xfs_io
trap 'p2p_cleanup; dmsetup remove legA 2>/dev/null; dmsetup remove legB 2>/dev/null; rmmod dm_errstat 2>/dev/null; rmmod brd 2>/dev/null' EXIT
p2p_load_ms_modules
modprobe brd rd_nr=2 rd_size=32768
p2p_load_dm_errstat
dmsetup create legA --table "0 $(blockdev --getsz /dev/ram0) errstat /dev/ram0 p2pdma"
dmsetup create legB --table "0 $(blockdev --getsz /dev/ram1) errstat /dev/ram1 p2pdma"
ARR="$(p2p_make_array 1 /dev/mapper/legA /dev/mapper/legB)"
dmsetup message legA 0 arm
dmsetup message legB 0 arm

out="$(xfs_io -d -c "pwrite -S 0x5a 0 4096" "$ARR" 2>&1)"
rc=$?
dmsetup message legA 0 disarm
dmsetup message legB 0 disarm

echo "xfs_io output: $out"
[ "$rc" -ne 0 ] \
	|| p2p_fail "total-P2PDMA-failure write reported SUCCESS to the caller (rc=0) -- the outbound clamp regressed"

p2p_pass "total P2PDMA failure never surfaced as a successful completion (rc=$rc)"
