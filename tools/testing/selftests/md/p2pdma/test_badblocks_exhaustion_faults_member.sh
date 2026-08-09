#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
# The deliberate opposite of test_badblocks_bounded_not_faulted.sh: drive
# a single leg's badblock table past MAX_BADBLOCKS ($MAX_BADBLOCKS,
# PAGE_SIZE/8 on a 4K-page host) with scattered (non-coalescing)
# P2PDMA-failed writes. rdev_set_badblocks() calls md_error() internally
# once the table is full, so THIS test asserts the member DOES become
# Faulty and the array DOES degrade -- the accepted, must-not-silently-
# regress end state once a member has run out of room to record fencing.
#
# Deliberately uses ORDINARY (non-P2P-tagged) writes rather than
# p2p_io/md_p2p_test: MAX_BADBLOCKS+ iterations of insmod/rmmod would be
# needlessly slow, and (as established in the sibling tests) the
# badblock-exhaustion mechanism reacts to bio->bi_status alone, not to
# whether the bio was P2P-tagged.
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
trap 'p2p_cleanup; dmsetup remove legB 2>/dev/null; rmmod dm_errstat 2>/dev/null; rmmod brd 2>/dev/null' EXIT
p2p_load_ms_modules

WRITES=$((MAX_BADBLOCKS + 8))
STRIDE_SECTORS=4096
RD_SIZE_KB=$(( (WRITES + 4) * STRIDE_SECTORS / 2 ))

modprobe brd rd_nr=2 rd_size="$RD_SIZE_KB"
p2p_load_dm_errstat
dmsetup create legB --table "0 $(blockdev --getsz /dev/ram1) errstat /dev/ram1 p2pdma"
ARR="$(p2p_make_array 1 /dev/ram0 /dev/mapper/legB)"
dmsetup message legB 0 arm
RDB="$(p2p_rd_dir_for_dev "$ARR" /dev/mapper/legB)" || p2p_fail "cannot find legB's rdev sysfs dir"

faulted_at=0
i=0
while [ "$i" -lt "$WRITES" ]; do
	off=$(( i * STRIDE_SECTORS * 512 ))
	# Once legB faults, the array only has one live copy left; keep
	# writing (harmlessly -- legA alone still services it) purely to
	# reach and confirm the fault, not to depend on any particular RC.
	p2p_ordinary_write "$ARR" "$off" 512 >/dev/null 2>&1
	if p2p_is_faulty "$RDB"; then
		faulted_at=$((i + 1))
		break
	fi
	i=$((i + 1))
done
dmsetup message legB 0 disarm 2>/dev/null

[ "$faulted_at" -gt 0 ] \
	|| p2p_fail "legB never faulted after $WRITES scattered P2PDMA writes -- badblock exhaustion did not degrade the array"
[ "$faulted_at" -le "$WRITES" ] \
	|| p2p_fail "internal: faulted_at ($faulted_at) exceeds WRITES ($WRITES)"

p2p_member_state "$ARR" | grep -q "Failed Devices : 0" \
	&& p2p_fail "legB is marked faulty in rdev state but mdadm --detail still reports 0 failed devices"

p2p_pass "badblock table exhaustion (at write #$faulted_at of $WRITES, limit $MAX_BADBLOCKS): legB correctly faulted, array degraded"
