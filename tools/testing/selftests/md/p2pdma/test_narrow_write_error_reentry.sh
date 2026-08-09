#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
# The §1.6a regression guard (design spec 2026-07-29-p2pdma-v6-rework-
# design.md, "narrow_write_error() defeats the outbound clamp"). A
# P2P-tagged write whose FIRST (whole-leg) attempt on legB fails with a
# genuine, non-P2P status (stands in for e.g. a real medium error) --
# then, on a build MISSING dkms/patches/0012 entirely, falls into
# narrow_write_error()'s per-block retry loop, where every retry chunk
# then hits a literal BLK_STS_P2PDMA. The dm-errstat "first,rest"
# sequenced arm produces exactly this without any racy userspace timing:
# the first armed completion returns <first>, every one after it
# returns <rest>.
#
# CORRECTION (fix round 1): on a FULLY patched build this test's PASS
# comes from hunk 4, not hunk 5/narrow_write_error() -- an earlier
# version of this comment attributed it to the latter. Hunk 4 changes
# handle_write_finished()'s dispatch to
# `if (test_bit(R1BIO_P2PDMA, &r1_bio->state) || bio->bi_status == BLK_STS_P2PDMA)`:
# since THIS bio is tagged (p2p_io/md_p2p_test builds it entirely from
# CMB pages), that condition is already true on the FIRST completion --
# whatever its status -- so rdev_set_badblocks() is called immediately
# for the whole range and narrow_write_error() is never entered at all.
# Hunk 5 (the explicit `wbio->bi_status == BLK_STS_P2PDMA` check inside
# narrow_write_error(), after `submit_bio_wait()`) exists for the case
# hunk 4 cannot reach: an UNTAGGED write, where R1BIO_P2PDMA is never set.
# That case is asserted by test_narrow_write_error_untagged.sh, which is
# this file's untagged twin -- same dm-errstat "5,p2pdma" arm, ordinary
# pwrite instead of p2p_io, so the first completion declines hunk 4 and
# narrow_write_error() is actually entered. (It used to be nominated to
# test_mixed_pgmap_untagged.sh, which asserts nothing and cannot even
# build its bio on >= 6.17 kernels, so hunk 5 was in practice unguarded.)
#
# THE BUG THIS GUARDS (still real and still worth a comment, even though
# the healthy-build pass path is hunk 4): a build missing 0012
# altogether has neither the tag-gated dispatch nor the explicit status
# check. handle_write_finished() then only checks `bi_status ==
# BLK_STS_P2PDMA` directly (v6's original, unpatched form); the FIRST
# completion (status=<first>, not P2PDMA) misses that check and falls
# into narrow_write_error(), which decides whether to record a badblock
# from `submit_bio_wait(wbio) && !rdev_set_badblocks(...)`.
# submit_bio_wait()'s return is blk_status_to_errno(bio->bi_status) --
# and on a kernel with no native BLK_STS_P2PDMA, blk_status_to_errno(18)
# is 0 (a zero-filled hole in blk_errors[], see dkms/compat/compat.h).
# So each retry chunk (status=<rest>=p2pdma) is silently recorded as
# written when it was not -- the mirror diverges with nothing on record.
# This makes the test fundamentally a COMPAT-KERNEL guard for the
# "0012 missing entirely" regression: on a native BLK_STS_P2PDMA kernel
# blk_status_to_errno(18) is a real nonzero errno by upstream
# definition, so even fully-unpatched code already gets this right, and
# the test should pass regardless. On a compat kernel it passes ONLY
# when run against modules built through the real DKMS pipeline (which
# is what MS_MOD_DIR is expected to contain; see the task-10 report).
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
# 5 = BLK_STS_IOERR (a real, non-P2P error) on the first attempt; every
# subsequent (narrow-retry) attempt gets literal BLK_STS_P2PDMA.
dmsetup create legB --table "0 $(blockdev --getsz /dev/ram1) errstat /dev/ram1 5,p2pdma"
ARR="$(p2p_make_array 1 /dev/ram0 /dev/mapper/legB)"
FILL=5a
NSEC=16   # md_p2p_test's default kib=8 -> 16 sectors: several narrow-retry chunks

dmsetup message legB 0 arm
RC="$(p2p_io write "$ARR" "$(p2p_bdf_by_serial cmb0)" fill=0x$FILL)"
dmsetup message legB 0 disarm
dmsetup message legB 0 reset

[ "$RC" = "0" ] || p2p_fail "write returned errno=$RC, want 0 (legA is healthy throughout)"

OFFB="$(p2p_data_offset_sectors /dev/mapper/legB)"
[ -n "$OFFB" ] || p2p_fail "could not resolve Data Offset for legB"
RDB="$(p2p_rd_dir_for_dev "$ARR" /dev/mapper/legB)" || p2p_fail "cannot find legB's rdev sysfs dir"
BBB="$RDB/bad_blocks"

p2p_bb_nonempty "$BBB" \
	|| p2p_fail "REGRESSION: no badblock recorded on legB -- narrow_write_error() silently dropped a failed retry chunk (blk_status_to_errno(18)==0 bug; see comment header)"
p2p_bb_covers "$BBB" "$OFFB" "$NSEC" \
	|| p2p_fail "badblocks ($(cat "$BBB")) do not cover the full retried range [$OFFB, $((OFFB + NSEC))) -- some retry chunk was silently dropped"

p2p_pass "narrow_write_error() re-entry: the whole retried range is fenced, none of it silently dropped"
