#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
# Hunk 5's only guard: an iovec MIXING host and device (P2P) pages, with
# the FIRST segment a host page (md_p2p_test's mixed=1). A bio is tagged
# as P2P purely from bi_io_vec[0] (see md_bio_is_p2pdma() in the md
# tree), so this bio is never tagged even though most of its payload is
# device memory -- it takes the ORDINARY (non-P2P) error path, and
# whatever failure detection happens for the device-page segments
# happens below md, in the real transport.
#
# This is real-topology-only, deliberately: a synthetic dm-errstat leg
# always returns one status for the WHOLE bio, so it cannot reproduce
# "some segments failed to map, others didn't, and the transport's own
# completion aggregation swallowed the failure" -- which is exactly the
# scenario this test needs.
#
# KERNEL DEPENDENCE. From 6.17 on, bio_add_page() refuses a page whose
# pgmap does not match the previous bvec's, so this bio CANNOT BE BUILT
# at all -- the scenario is structurally impossible and there is nothing
# here to exercise. This test SKIPs there, and the rule itself is
# asserted by its sibling test_kernel_rejects_mixed_pgmap.sh, which is
# also what makes the skip self-correcting: if a future kernel drops the
# rule, that test flips and this one starts running for real again.
# On 6.12/6.14-class kernels (the RHEL 10 / Rocky 10 target) the bio IS
# constructible, the hazard is live, and this test runs as written.
#
# Per the design doc this remains a KNOWN, ACCEPTED residual on the
# kernels where it is reachable: the write may report success despite a
# real divergence on the unreachable leg, or may fail with a nonzero
# errno and be fenced correctly (the ordinary, untagged write-error
# path, same as test_status_matrix_injected.sh's TARGET cell). Because
# the correct outcome is kernel-dependent and this box cannot pin down
# which shape a given target kernel takes, this test records what it
# observes rather than asserting one of the two shapes. The one thing it
# DOES hard-assert is that nothing gets faulted, which holds regardless
# (this suite never configures failfast) -- a fault here would mean
# something worse than either documented shape.
#
# What it also hard-asserts, and did not before, is that the I/O
# ACTUALLY RAN. p2p_io returns nonzero and echoes nothing when the bio
# never reached the device; unchecked, that left RC empty, and since a
# leg that was never written to trivially "diverges with nothing
# recorded", the run reported the accepted-residual shape and PASSED --
# an infrastructure failure laundered into a design-sanctioned verdict.
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
LEG2="$(p2p_nvme_by_serial leg2)"
ARR="$(p2p_make_array 1 "$(p2p_nvme_by_serial leg1)" "$LEG2")"
FILL=c3
NSEC=16   # kib=8 -> 2 pages (host + 1 device page), satisfies mixed's npages>=2
CMB="$(p2p_bdf_by_serial cmb0)"

p2p_mixed_bio_allowed "$ARR" "$CMB"
case "$?" in
1) p2p_skip "kernel refuses a host+P2P bio (>= 6.17 bio_add_page pgmap rule) -- the mixed-pgmap scenario cannot be constructed; the rule is asserted by test_kernel_rejects_mixed_pgmap.sh" ;;
2) p2p_fail "mixed-pgmap probe was indeterminate -- cannot tell whether this kernel permits a host+P2P bio, so neither running nor skipping this test would be honest (see dmesg for md_p2p_test: mixed_pgmap_probe)" ;;
esac

RC="$(p2p_io write "$ARR" "$CMB" mixed=1 kib=8 fill=0x$FILL)" \
	|| p2p_fail "the mixed-pgmap write never reached the device -- no result line from md_p2p_test (see dmesg). The probe above says this kernel PERMITS a host+P2P bio, so this is a rig or module failure, not the kernel's composition rule"
[ -n "$RC" ] || p2p_fail "p2p_io returned success but reported no errno -- refusing to interpret a leg that may never have been written"
echo "note: mixed-pgmap (untagged) write returned errno=$RC"

OFF2="$(p2p_data_offset_sectors "$LEG2")"
RD2="$(p2p_rd_dir_for_dev "$ARR" "$LEG2")" || p2p_fail "cannot find leg2's rdev sysfs dir"

if [ -n "$OFF2" ] && p2p_raw_all_byte "$LEG2" "$OFF2" "$NSEC" "$FILL"; then
	echo "OBSERVED: leg2 has the correct pattern (this kernel's transport did not diverge here)"
elif p2p_bb_nonempty "$RD2/bad_blocks"; then
	echo "OBSERVED: leg2 diverges but is badblocked -- fenced correctly (6.12/6.14-class shape)"
else
	echo "OBSERVED: leg2 diverges with no badblock recorded -- the accepted residual (design doc section 7)"
fi

p2p_member_state "$ARR" | grep -q "Failed Devices : 0" \
	|| p2p_fail "a member was faulted (worse than either documented shape; failfast is not configured)"
p2p_wants_replacement "$RD2" \
	&& echo "note: leg2 got WantReplacement (ordinary-error path was taken, consistent with the untagged bio)"

p2p_pass "mixed-pgmap (untagged): behaviour recorded above, nothing faulted"
