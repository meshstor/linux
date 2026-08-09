#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
# Asserts THIS kernel's bio-composition rule for P2P pages, and that
# md_p2p_test's mixed=1 path agrees with it.
#
# From 6.17 on, bio_add_page() refuses a page whose pgmap does not match
# the previous bvec's, so a host page followed by a P2P page cannot be
# put in one bio. That is the invariant drivers/md/md.h states above
# md_bio_is_p2pdma() -- "P2P and host pages never mix within a bio, so
# the first bvec is representative" -- and it is why reading bi_io_vec[0]
# is exact there rather than a heuristic. Upstream enforces it for its
# own reasons: blk_dma_map_iter_start() caches the P2PDMA mapping state
# from the FIRST segment and applies it to the rest, so a bio must be
# pgmap-homogeneous or the mapping would be wrong.
#
# 6.12/6.14-class kernels (the RHEL 10 / Rocky 10 target) have no such
# rule, so md.h's invariant is NOT guaranteed there: a crafted iovec can
# still produce a mixed bio. It degrades safely -- such a bio is
# untagged, fails BLK_STS_TARGET, and takes md's ordinary write-error
# path, which fences it -- and that is the residual
# test_mixed_pgmap_untagged.sh exercises.
#
# So both answers are legitimate and this test passes on either; what it
# hard-asserts is that the answer is UNAMBIGUOUS and that the two ways of
# reaching it agree. Three ways to fail:
#   - the probe's own controls (host+host, dev+dev) did not both pass, so
#     the probe proves nothing about pgmap and any verdict from it would
#     be an inference dressed up as a measurement;
#   - the kernel rejects mixed bios but md_p2p_test's mixed=1 path still
#     built one (or vice versa) -- the probe and the real path disagree,
#     so one of them is lying;
#   - the mixed=1 path failed for some reason OTHER than the pgmap rule,
#     which would otherwise be indistinguishable from the rule firing.
#
# This is what makes test_mixed_pgmap_untagged.sh's skip self-correcting:
# if a kernel ever drops the rule, this test's verdict flips here, loudly,
# instead of that test skipping forever on a stale assumption.
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
trap p2p_cleanup EXIT
p2p_load_ms_modules
ARR="$(p2p_make_array 1 "$(p2p_nvme_by_serial leg1)" "$(p2p_nvme_by_serial leg2)")"
CMB="$(p2p_bdf_by_serial cmb0)"

p2p_mixed_bio_allowed "$ARR" "$CMB"
allowed=$?
PROBE="$(dmesg | grep 'md_p2p_test: mixed_pgmap_probe' | tail -1)"
[ "$allowed" -ne 2 ] \
	|| p2p_fail "probe indeterminate -- its host+host / dev+dev controls did not both pass, so it proves nothing about the pgmap rule: ${PROBE:-<no probe line in dmesg>}"
echo "note: $PROBE"

# Cross-check the probe against the path that actually matters. mixed=1
# builds the real thing; if it can be built there is a result line, and if
# the pgmap rule refused it there is the distinct rejection line instead.
rmmod md_p2p_test 2>/dev/null || true
before=$(dmesg | grep -c 'md_p2p_test: result' || true)
insmod "$MODULES_DIR/md_p2p_test.ko" \
	provider="$CMB" target="$ARR" op=write mixed=1 kib=8 fill=0xc3 \
	>/dev/null 2>&1 || true
after=$(dmesg | grep -c 'md_p2p_test: result' || true)
rmmod md_p2p_test 2>/dev/null || true
built=$([ "$after" -gt "$before" ] && echo yes || echo no)
rejected=$(dmesg | grep -q 'md_p2p_test: mixed_pgmap_rejected' && echo yes || echo no)

if [ "$allowed" -eq 1 ]; then
	[ "$built" = no ] \
		|| p2p_fail "probe says this kernel REFUSES a host+P2P bio, yet mixed=1 built one and submitted I/O -- probe and real path disagree"
	[ "$rejected" = yes ] \
		|| p2p_fail "probe says this kernel REFUSES a host+P2P bio and mixed=1 submitted nothing, but not via the pgmap rule (no mixed_pgmap_rejected line) -- it failed for some other reason, see dmesg"
	p2p_pass "kernel enforces pgmap-homogeneous bios (>= 6.17 rule): md.h's md_bio_is_p2pdma() first-bvec invariant holds here, and the mixed-pgmap residual is structurally unreachable"
fi

[ "$built" = yes ] \
	|| p2p_fail "probe says this kernel PERMITS a host+P2P bio, yet mixed=1 produced no result line -- probe and real path disagree, or the rig is broken"
[ "$rejected" = no ] \
	|| p2p_fail "probe says this kernel PERMITS a host+P2P bio, yet mixed=1 reported the pgmap rejection -- probe and real path disagree"
p2p_pass "kernel permits mixed-pgmap bios (6.12/6.14-class): md.h's first-bvec invariant is NOT guaranteed here and the untagged residual is live -- test_mixed_pgmap_untagged.sh exercises it"
