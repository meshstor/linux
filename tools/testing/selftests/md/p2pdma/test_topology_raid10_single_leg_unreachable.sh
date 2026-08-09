#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
# raid10 arm of test_topology_single_leg_unreachable.sh: 2-device raid10
# (mirrored layout), leg2 P2P-unreachable from the CMB (asymmetric
# switch layout). Same PRECONDITION and mechanism as that file (0012's
# hunk 2 inbound translation + hunk 4 tag-gated dispatch, both mirrored
# in raid10.c for the raid10 personality) -- see its header comment for
# the full explanation; not repeated here.
#
# v6 semantics on a fully-patched build: the write succeeds off leg1,
# leg2's range is badblocked, leg2 is not faulted and gets no
# WantReplacement. On the pre-rework base this observed the bug in its
# raid10 form: the write reported SUCCESS while silently NOT having
# reached leg2, with no badblock recorded to say so.
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/lib.sh"
if [ -z "${P2P_IN_VM:-}" ]; then
	p2p_require_rig
	exec "$DIR/run_vm.sh" asymmetric \
		env P2P_IN_VM=1 MS_MOD_DIR="${MS_MOD_DIR:-}" \
		MDADM="${MDADM:-}" MD_SUBSYS="${MD_SUBSYS:-}" \
		"$DIR/$(basename "$0")"
fi
p2p_require_root; p2p_require_rig
trap p2p_cleanup EXIT
p2p_load_ms_modules
LEG1="$(p2p_nvme_by_serial leg1)"
LEG2="$(p2p_nvme_by_serial leg2)"
ARR="$(p2p_make_array 10 "$LEG1" "$LEG2")"
FILL=5a
NSEC=16

RC="$(p2p_io write "$ARR" "$(p2p_bdf_by_serial cmb0)" fill=0x$FILL)"
[ "$RC" = "0" ] || p2p_fail "raid10 asymmetric p2p write returned errno=$RC, want 0"

OFF1="$(p2p_data_offset_sectors "$LEG1")"
OFF2="$(p2p_data_offset_sectors "$LEG2")"
[ -n "$OFF1" ] || p2p_fail "could not resolve Data Offset for leg1"
[ -n "$OFF2" ] || p2p_fail "could not resolve Data Offset for leg2"

RD2="$(p2p_rd_dir_for_dev "$ARR" "$LEG2")" || p2p_fail "cannot find leg2's rdev sysfs dir"
BB2="$RD2/bad_blocks"

p2p_raw_all_byte "$LEG1" "$OFF1" "$NSEC" "$FILL" \
	|| p2p_fail "leg1 (the P2P-reachable leg) does not have the written pattern"

p2p_bb_nonempty "$BB2" \
	|| p2p_fail "no badblock recorded on leg2 for its topology-miss write"
p2p_bb_covers "$BB2" "$OFF2" "$NSEC" \
	|| p2p_fail "leg2 badblocks ($(cat "$BB2")) do not cover the full written range [$OFF2, $((OFF2 + NSEC)))"
p2p_wants_replacement "$RD2" \
	&& p2p_fail "leg2 got WantReplacement for a topology miss"
p2p_is_faulty "$RD2" \
	&& p2p_fail "leg2 was faulted for a topology miss"

p2p_pass "raid10 single-leg-unreachable: write succeeds off leg1, leg2 fenced (no WantReplacement, not faulted)"
