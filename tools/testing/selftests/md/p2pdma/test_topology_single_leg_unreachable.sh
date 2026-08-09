#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
# raid1, real (not injected) PCIe topology: leg2 is P2P-unreachable from
# the CMB (asymmetric switch layout), leg1 is reachable.
#
# PRECONDITION, same as test_narrow_write_error_reentry.sh: this asserts
# the full v6 truth table, which requires MS_MOD_DIR to hold modules
# built through the real DKMS pipeline (dkms/patches/0012 applied), not
# a raw build straight from this branch's drivers/md.
#
# Design doc §"Task 8: 0012 -- the status compat patch" records the
# VERIFIED per-kernel behaviour for a genuine local-nvme-pci topology
# miss: 6.12/6.14-class kernels report BLK_STS_TARGET, 6.17/7.0-class
# report BLK_STS_INVAL. Both would, unpatched, be handled as an ordinary
# (TARGET) or silently-ignored (INVAL, excluded by upstream's own "don't
# fail devices for invalid IO errors") status -- neither routes through
# the P2P logic at all, and INVAL in particular would leave the mirror
# silently diverged. 0012's hunk 2 (inbound translation) exists
# specifically to close that gap: for a P2P-TAGGED bio (what p2p_io /
# md_p2p_test builds -- every page here comes from the CMB provider, so
# bi_io_vec[0] is a device page and R1BIO_P2PDMA gets set at submit),
# BOTH BLK_STS_INVAL and BLK_STS_TARGET are rewritten to literal
# BLK_STS_P2PDMA at member completion, before raid1_write_error() ever
# runs. Hunk 4 then takes the direct rdev_set_badblocks() arm for any
# tagged bio regardless of status, as a second, redundant guarantee.
#
# So on a fully-patched build this reduces to exactly the synthetic
# case test_status_matrix_injected.sh already hard-asserts: badblock
# recorded, no WantReplacement, member not faulted, RC=0 (succeeds off
# leg1). The raw byte-level divergence check is kept as well (not just
# the badblocks flag), using the same strict range-coverage the
# divergence oracle uses, since real hardware is the whole point of
# this file.
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
ARR="$(p2p_make_array 1 "$LEG1" "$LEG2")"
FILL=a5
NSEC=16   # md_p2p_test's default kib=8 -> 16 sectors of 512 bytes

RC="$(p2p_io write "$ARR" "$(p2p_bdf_by_serial cmb0)" fill=0x$FILL)"
[ "$RC" = "0" ] || p2p_fail "asymmetric p2p write returned errno=$RC, want 0 (v6: succeeds off leg1)"

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
	&& p2p_fail "leg2 got WantReplacement for a topology miss (should be silent)"
p2p_is_faulty "$RD2" \
	&& p2p_fail "leg2 was faulted for a topology miss"

p2p_pass "single-leg-unreachable: write succeeds off leg1, leg2 fenced (no WantReplacement, not faulted)"
