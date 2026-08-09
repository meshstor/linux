#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
# "Member not faulted" for a P2PDMA write only holds while the badblock
# table has room: rdev_set_badblocks() calls md_error() internally once
# its MAX_BADBLOCKS (PAGE_SIZE/8 = 512 on a 4K-page host) entries are
# exhausted. This test stays deliberately well below that bound -- 16
# scattered (non-adjacent, so they can't coalesce into one entry)
# P2PDMA-failed writes on one leg -- and asserts the member stays
# healthy throughout. See test_badblocks_exhaustion_faults_member.sh for
# the deliberate opposite: past the limit, a fault IS expected.
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

WRITES=16
STRIDE_SECTORS=4096   # >> the ~1-8 sector badblock granularity: no coalescing
RD_SIZE_KB=$(( (WRITES + 4) * STRIDE_SECTORS / 2 ))   # /2: sectors(512B) -> KiB

modprobe brd rd_nr=2 rd_size="$RD_SIZE_KB"
p2p_load_dm_errstat
dmsetup create legB --table "0 $(blockdev --getsz /dev/ram1) errstat /dev/ram1 p2pdma"
ARR="$(p2p_make_array 1 /dev/ram0 /dev/mapper/legB)"
dmsetup message legB 0 arm
RDB="$(p2p_rd_dir_for_dev "$ARR" /dev/mapper/legB)" || p2p_fail "cannot find legB's rdev sysfs dir"

i=0
while [ "$i" -lt "$WRITES" ]; do
	off=$(( i * STRIDE_SECTORS * 512 ))
	p2p_ordinary_write "$ARR" "$off" 512 \
		|| p2p_fail "write #$i (bounded, should succeed off legA) failed"
	p2p_is_faulty "$RDB" && p2p_fail "legB faulted after only $((i + 1))/$WRITES writes (well under MAX_BADBLOCKS=$MAX_BADBLOCKS)"
	i=$((i + 1))
done
dmsetup message legB 0 disarm

p2p_bb_nonempty "$RDB/bad_blocks" || p2p_fail "no badblocks recorded after $WRITES failed writes"
ENTRIES="$(p2p_bb_count_entries "$RDB/bad_blocks")"
[ "$ENTRIES" -ge 1 ] || p2p_fail "expected at least one badblock entry, counted $ENTRIES"
p2p_wants_replacement "$RDB" && p2p_fail "legB got WantReplacement for P2PDMA-only failures"
p2p_is_faulty "$RDB" && p2p_fail "legB was faulted"

p2p_pass "$WRITES scattered P2PDMA writes: legB badblocked ($ENTRIES entries), not faulted, no WantReplacement"
