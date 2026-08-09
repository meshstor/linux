#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
# Mixed-error arm: legA completes with literal BLK_STS_P2PDMA (a p2p
# miss), legB with BLK_STS_IOERR (a real device error) -- on the SAME
# write. An ordinary (non-P2P-tagged) write is used deliberately: the
# core status-based logic in handle_write_finished()/raid1_write_error()
# reacts to bio->bi_status alone, not to whether the bio was P2P-tagged,
# so this isolates that logic from any tag-related ambiguity.
#
# v6 semantics: with BOTH legs failing on the same write, neither
# contributes R1BIO_Uptodate, so the master write fails HONESTLY (a real
# errno) -- it must NOT report success with a half-written mirror. Each
# leg is still handled per its own failure class: legA (P2PDMA) gets a
# badblock and nothing else; legB (a real error) gets a badblock AND
# WantReplacement. Neither is faulted (this suite never sets failfast).
#
# On the pre-rework base, both TARGET and INVAL-class statuses were
# treated as p2p overrides, and this scenario's old counterpart asserted
# "P2P override wins, master returns -EINVAL, legB unblemished" -- wrong
# on two counts under v6: only literal BLK_STS_P2PDMA is special-cased,
# and a real device error must still show up as such.
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
dmsetup create legB --table "0 $(blockdev --getsz /dev/ram1) errstat /dev/ram1 5"
ARR="$(p2p_make_array 1 /dev/mapper/legA /dev/mapper/legB)"
dmsetup message legA 0 arm
dmsetup message legB 0 arm
RC=0
p2p_ordinary_write "$ARR" 0 4096 || RC=1
dmsetup message legA 0 disarm
dmsetup message legB 0 disarm

[ "$RC" != 0 ] || p2p_fail "mixed-error write reported success with both legs failing -- silent divergence"

RDA="$(p2p_rd_dir_for_dev "$ARR" /dev/mapper/legA)" || p2p_fail "cannot find legA's rdev sysfs dir"
RDB="$(p2p_rd_dir_for_dev "$ARR" /dev/mapper/legB)" || p2p_fail "cannot find legB's rdev sysfs dir"

p2p_bb_nonempty "$RDA/bad_blocks" || p2p_fail "legA (P2PDMA) has no badblock recorded"
p2p_bb_nonempty "$RDB/bad_blocks" || p2p_fail "legB (real error) has no badblock recorded"
p2p_wants_replacement "$RDA" && p2p_fail "legA (P2PDMA) got WantReplacement -- should be silent"
p2p_wants_replacement "$RDB" || p2p_fail "legB (real error) did not get WantReplacement"
p2p_is_faulty "$RDA" && p2p_fail "legA was faulted (failfast not configured)"
p2p_is_faulty "$RDB" && p2p_fail "legB was faulted (failfast not configured)"

p2p_pass "mixed error: honest failure, both legs fenced, only the real error got WantReplacement"
