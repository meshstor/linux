#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
# raid1, real (not injected) PCIe topology: NO leg is P2P-reachable from
# the CMB (both on separate root ports).
#
# PRECONDITION, same as test_narrow_write_error_reentry.sh and
# test_topology_single_leg_unreachable.sh: this asserts the full v6
# truth table, which requires MS_MOD_DIR to hold modules built through
# the real DKMS pipeline (dkms/patches/0012 applied). See
# test_topology_single_leg_unreachable.sh's header for the full
# mechanism (0012's hunk 2 inbound translation of a genuine local
# BLK_STS_INVAL/BLK_STS_TARGET topology miss to literal BLK_STS_P2PDMA
# for a P2P-tagged bio, plus hunk 4's tag-gated dispatch); not repeated
# here.
#
# With BOTH legs genuinely unreachable, BOTH get translated to literal
# P2PDMA and badblocked -- but neither contributes R1BIO_Uptodate, so
# unlike the single-leg case the master WRITE must fail HONESTLY (a
# real errno, never a false success -- this is the total-failure
# counterpart to test_errno_never_zero_on_total_failure.sh's synthetic
# case). Likewise the READ: raid1_end_read_request()'s retry-to-other-
# leg path (gated on literal BLK_STS_P2PDMA) marks each attempted leg
# IO_BLOCKED and moves to the next, but with every leg unreachable,
# read_balance() eventually finds none usable and the read fails
# honestly too (raid1_read_request()'s `rdisk < 0` path).
#
# The read side additionally pre-populates the region via an ORDINARY
# (non-P2P) write first, so both legs are known to hold correct data
# independent of P2P reachability, and checks the P2P read with
# md_p2p_test's check_fill (forces the reported errno non-zero on any
# content mismatch) as a second, redundant guarantee: even if this
# host's real behaviour ever surprised us and returned RC=0, that would
# still only be possible with genuinely correct data, never silently
# wrong data reported as success.
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/lib.sh"
if [ -z "${P2P_IN_VM:-}" ]; then
	p2p_require_rig
	exec "$DIR/run_vm.sh" unreachable \
		env P2P_IN_VM=1 MS_MOD_DIR="${MS_MOD_DIR:-}" \
		MDADM="${MDADM:-}" MD_SUBSYS="${MD_SUBSYS:-}" \
		"$DIR/$(basename "$0")"
fi
p2p_require_root; p2p_require_rig
trap p2p_cleanup EXIT
p2p_load_ms_modules
LEG1="$(p2p_nvme_by_serial leg1)"
LEG2="$(p2p_nvme_by_serial leg2)"
ARR="$(p2p_make_array 1 "$LEG1" "$LEG2")"
FILL=a5
NSEC=16

# --- write side: both legs fail, but honestly (never a false success) -----
RC="$(p2p_io write "$ARR" "$(p2p_bdf_by_serial cmb0)" sector=0 fill=0x$FILL)"
[ "$RC" != "0" ] \
	|| p2p_fail "all-unreachable write reported SUCCESS (rc=0) with every leg failing -- silent total-loss divergence"

OFF1="$(p2p_data_offset_sectors "$LEG1")"
OFF2="$(p2p_data_offset_sectors "$LEG2")"
[ -n "$OFF1" ] || p2p_fail "could not resolve Data Offset for leg1"
[ -n "$OFF2" ] || p2p_fail "could not resolve Data Offset for leg2"

RD1="$(p2p_rd_dir_for_dev "$ARR" "$LEG1")" || p2p_fail "cannot find leg1's rdev sysfs dir"
RD2="$(p2p_rd_dir_for_dev "$ARR" "$LEG2")" || p2p_fail "cannot find leg2's rdev sysfs dir"
BB1="$RD1/bad_blocks"
BB2="$RD2/bad_blocks"

p2p_bb_nonempty "$BB1" || p2p_fail "no badblock recorded on leg1"
p2p_bb_covers "$BB1" "$OFF1" "$NSEC" \
	|| p2p_fail "leg1 badblocks ($(cat "$BB1")) do not cover the full written range [$OFF1, $((OFF1 + NSEC)))"
p2p_bb_nonempty "$BB2" || p2p_fail "no badblock recorded on leg2"
p2p_bb_covers "$BB2" "$OFF2" "$NSEC" \
	|| p2p_fail "leg2 badblocks ($(cat "$BB2")) do not cover the full written range [$OFF2, $((OFF2 + NSEC)))"
p2p_wants_replacement "$RD1" && p2p_fail "leg1 got WantReplacement for a topology miss"
p2p_wants_replacement "$RD2" && p2p_fail "leg2 got WantReplacement for a topology miss"
p2p_is_faulty "$RD1" && p2p_fail "leg1 was faulted for a topology miss"
p2p_is_faulty "$RD2" && p2p_fail "leg2 was faulted for a topology miss"

# --- read side: pre-populate with an ordinary (non-P2P) write, then read via P2P
RSEC=1024
p2p_write_pattern "$ARR" "$RSEC" "$NSEC" "$FILL"
p2p_raw_all_byte "$ARR" "$RSEC" "$NSEC" "$FILL" \
	|| p2p_fail "could not pre-populate the read-test region via the ordinary path"

RC="$(p2p_io read "$ARR" "$(p2p_bdf_by_serial cmb0)" sector=$RSEC check_fill=0x$FILL)"
[ "$RC" != "0" ] \
	|| p2p_fail "all-unreachable p2p read reported SUCCESS (rc=0) with every leg unreachable -- expected an honest failure (check_fill already rules out a wrong-data false success, so this would mean read_balance()/retry unexpectedly found a usable leg)"

p2p_pass "all-unreachable: both legs fenced with no WantReplacement/fault, write and read both fail honestly"
