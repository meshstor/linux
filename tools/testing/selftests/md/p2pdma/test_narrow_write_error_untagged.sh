#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
# The asserting guard for dkms/patches/0012 hunk 5 -- the explicit
# `wbio->bi_status == BLK_STS_P2PDMA` check inside narrow_write_error(),
# after submit_bio_wait().
#
# WHY THIS FILE EXISTS. Hunk 5 covers what hunk 4 cannot reach: a bio
# that is NOT P2P-tagged, whose per-block retry chunks come back
# BLK_STS_P2PDMA. Until now the only test pointed at it was
# test_mixed_pgmap_untagged.sh, which (a) asserts nothing -- it records
# observations -- and (b) cannot even build its bio on >= 6.17 kernels.
# So hunk 5 had no test that would notice if it were deleted. Its
# sibling test_narrow_write_error_reentry.sh does not cover it either:
# that one submits a TAGGED write via p2p_io, so hunk 4's tag-gated
# dispatch fires on the FIRST completion and narrow_write_error() is
# never entered at all (see that file's own CORRECTION note).
#
# The fix is not to build an exotic bio. narrow_write_error() is reached
# by any UNTAGGED write whose first completion is a non-P2PDMA failure --
# an ordinary pwrite will do -- and dm-errstat's sequenced "first,rest"
# arm supplies exactly the statuses needed, deterministically, on every
# target kernel, with no real P2P hardware and no mixed-pgmap bio.
#
#   ordinary (untagged) write  -> R1BIO_P2PDMA never set
#   first completion  = 5      -> BLK_STS_IOERR, not P2PDMA: hunk 4's
#                                 dispatch declines, narrow_write_error()
#                                 is entered
#   every retry chunk = p2pdma -> literal BLK_STS_P2PDMA
#
# THE BUG IT CATCHES. narrow_write_error() decides whether a chunk was
# written from `submit_bio_wait(wbio) && !rdev_set_badblocks(...)`.
# submit_bio_wait() returns blk_status_to_errno(bi_status), and on every
# kernel we ship to there is no native BLK_STS_P2PDMA -- index 18 is a
# zero-filled hole in blk_errors[], so blk_status_to_errno(18) is 0,
# i.e. SUCCESS. Without hunk 5 every retry chunk is therefore recorded as
# written when it was not: the range is never fenced and the mirror
# diverges with nothing on record. That is the silent-divergence failure
# this whole design exists to prevent.
#
# PRECONDITION, as for test_narrow_write_error_reentry.sh: MS_MOD_DIR
# must hold modules built through the real DKMS pipeline (0012 applied),
# not a raw build from this branch's drivers/md.
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
p2p_require_tool dmsetup
trap 'p2p_cleanup; dmsetup remove legB 2>/dev/null; rmmod dm_errstat 2>/dev/null; rmmod brd 2>/dev/null' EXIT
p2p_load_ms_modules
modprobe brd rd_nr=2 rd_size=65536
p2p_load_dm_errstat
# 5 = BLK_STS_IOERR on the first attempt; every subsequent (narrow-retry)
# attempt gets literal BLK_STS_P2PDMA.
dmsetup create legB --table "0 $(blockdev --getsz /dev/ram1) errstat /dev/ram1 5,p2pdma"
ARR="$(p2p_make_array 1 /dev/ram0 /dev/mapper/legB)"
FILL=0x7e
NSEC=16   # 8192 bytes: several narrow-retry chunks

dmsetup message legB 0 arm
RC=0
p2p_ordinary_write "$ARR" 0 8192 "$FILL" || RC=1
dmsetup message legB 0 disarm
dmsetup message legB 0 reset

[ "$RC" = "0" ] || p2p_fail "untagged write returned failure (legA is healthy throughout, so the master write must succeed off it)"

OFFB="$(p2p_data_offset_sectors /dev/mapper/legB)"
[ -n "$OFFB" ] || p2p_fail "could not resolve Data Offset for legB"
RDB="$(p2p_rd_dir_for_dev "$ARR" /dev/mapper/legB)" || p2p_fail "cannot find legB's rdev sysfs dir"
BBB="$RDB/bad_blocks"

p2p_bb_nonempty "$BBB" \
	|| p2p_fail "REGRESSION (0012 hunk 5): no badblock recorded on legB -- narrow_write_error() trusted blk_status_to_errno(BLK_STS_P2PDMA)==0 and recorded every failed retry chunk as written; the mirror is diverged with nothing on record"
p2p_bb_covers "$BBB" "$OFFB" "$NSEC" \
	|| p2p_fail "REGRESSION (0012 hunk 5): badblocks ($(cat "$BBB")) do not cover the full retried range [$OFFB, $((OFFB + NSEC))) -- some retry chunk was silently recorded as written"

# legB took a genuine BLK_STS_IOERR on its first attempt, so unlike a
# pure topology miss it SHOULD be escalated for replacement -- the P2PDMA
# carve-out must not leak into an ordinary device error.
p2p_wants_replacement "$RDB" \
	|| p2p_fail "legB did not get WantReplacement despite a genuine BLK_STS_IOERR first completion"
p2p_is_faulty "$RDB" && p2p_fail "legB was faulted (failfast is not configured)"

p2p_pass "narrow_write_error() untagged re-entry: every P2PDMA retry chunk fenced, none silently recorded as written"
