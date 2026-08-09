#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
#
# Bare-upstream baseline: assembling the ms_* DKMS package from verbatim upstream
# `master` (no meshstor feature branches) must succeed and be correctly gated for
# pre-6.11 kernels. This is the counterpart to test_0008 (which exercises the
# composed meshstor-main tree). It pins the contract that `bin/deploy-branch master`
# / `bin/build-tarball` against bare upstream produce a buildable pure-upstream-md
# baseline -- the A/B reference against meshstor's member-AND P2PDMA.
#
# What it proves:
#   * the `.patch.when` guards self-select the upstream raid variant: the member-AND
#     patches (0008, 0009) are SKIPPED (their helper is absent) and 0010 applies;
#   * upstream's two adjacent `lim.features |=` assignments (ATOMIC_WRITES and the
#     b8764f3 BLK_FEAT_PCI_P2PDMA) are wrapped TOGETHER in one
#     #ifdef HAVE_QUEUE_LIMITS_FEATURES block before the stack call, so they compile
#     out cleanly on kernels without queue_limits.features (pre-6.11);
#   * NONE of the meshstor-only p2pdma value-add (member-AND helper,
#     p2pdma_advertise knob, p2pdma_status report) leaks into the baseline;
#   * ms_mod/raid1_ms/raid10_ms link from the bare-upstream source.
#
# Re-keyed 2026-07-29 (v6 rework): 0009/0010's `.patch.when` guards already key
# on `raid1_can_advertise_p2pdma` (verified, not md_bio_is_p2pdma), so they
# needed no change here. This file's own leak-check did key on
# md_bio_is_p2pdma (as ms_bio_is_p2pdma post-rename) and DID need re-keying --
# upstream's v6 P2PDMA series upstreams that exact helper, so once v6 merges
# even a genuine bare-upstream tree carries it and the old assertion would
# break. See step 3 below for the fix.
#
# Needs a kernel tree carrying bare-upstream drivers/md (raw P2PDMA, NO member-AND
# helper). Discovery: $KERNEL_TREE -> build/linux-meshstor-rebuilt -> a temp
# worktree of the local `master` branch. SKIPs (exit 4) if none is available or
# the toolchain/kernel-build tree is missing.

set -u
# shellcheck source=tools/testing/selftests/dkms/lib.sh
. "$(dirname "$0")/lib.sh"

VER="0.0.0-selftest-p2pdma-baseline"
KDIR="${KDIR:-/lib/modules/$(uname -r)/build}"
OUT="$REPO_ROOT/build/meshstor-ms-$VER"
TARBALL="$REPO_ROOT/build/meshstor-ms-$VER.dkms.tar.gz"
WORKTREE=""   # set if we create a throwaway master worktree

# --- preconditions: missing toolchain/kernel tree is a SKIP -------------
command -v make >/dev/null 2>&1 || dkms_skip "make not available"
command -v gcc  >/dev/null 2>&1 || dkms_skip "gcc not available"
[ -d "$KDIR" ]          || dkms_skip "kernel build tree not found: $KDIR"
[ -f "$KDIR/Makefile" ] || dkms_skip "kernel build tree incomplete: $KDIR"

# Upstream's advertise compiles out on kernels without the modern P2PDMA flag;
# there is nothing meaningful to compile/assert there.
grep -q 'BLK_FEAT_PCI_P2PDMA' "$KDIR/include/linux/blkdev.h" 2>/dev/null \
	|| dkms_skip "running kernel lacks BLK_FEAT_PCI_P2PDMA (baseline compiles out; nothing to assert)"

baseline_cleanup() {
	rm -rf "$OUT" "$TARBALL"
	[ -n "$WORKTREE" ] && git -C "$REPO_ROOT" worktree remove --force "$WORKTREE" >/dev/null 2>&1
	return 0
}
trap 'baseline_cleanup; dkms_cleanup' EXIT
baseline_cleanup   # clear stale artifacts (WORKTREE still empty here)

# --- locate a BARE-UPSTREAM tree (has drivers/md, but NO member-AND helper) --
has_md()      { [ -f "$1/drivers/md/raid1.c" ] && [ -f "$1/drivers/md/md.c" ]; }
# bare upstream carries the raw advertise but NOT the meshstor helper:
is_upstream() { has_md "$1" \
	&& grep -q 'lim.features |= BLK_FEAT_PCI_P2PDMA' "$1/drivers/md/raid1.c" 2>/dev/null \
	&& ! grep -q 'raid1_can_advertise_p2pdma' "$1/drivers/md/raid1-10.c" 2>/dev/null; }
KT=""
if [ -n "${KERNEL_TREE:-}" ] && is_upstream "$KERNEL_TREE"; then
	KT="$KERNEL_TREE"
elif is_upstream "$REPO_ROOT/build/linux-meshstor-rebuilt"; then
	KT="$REPO_ROOT/build/linux-meshstor-rebuilt"
elif git -C "$REPO_ROOT" rev-parse --verify -q master >/dev/null; then
	WORKTREE="$(dkms_mktemp_dir)/ktree"
	if ! git -C "$REPO_ROOT" worktree add --detach "$WORKTREE" master >/dev/null 2>&1; then
		dkms_skip "could not create master worktree for bare-upstream drivers/md"
	fi
	is_upstream "$WORKTREE" || dkms_skip "master worktree is not bare-upstream (raw P2PDMA absent / helper present)"
	KT="$WORKTREE"
else
	dkms_skip "no bare-upstream drivers/md tree (set KERNEL_TREE=, run bin/rebuild-main, or provide master)"
fi

# --- 1. assemble via the production pipeline; capture the guard decisions ---
if ! tb_out="$(KERNEL_TREE="$KT" KDIR="$KDIR" \
		bash "$REPO_ROOT/bin/build-tarball" "$VER" 2>&1)"; then
	echo "FAIL: bin/build-tarball failed on bare-upstream tree $KT" >&2
	echo "$tb_out" | tail -30 >&2
	exit 1
fi
[ -d "$OUT" ] || dkms_fail "build-tarball did not produce $OUT"

# --- 2. the `.when` guards selected the upstream variant -------------------
case "$tb_out" in
	*"Skipping 0008-"*) : ;;
	*) dkms_fail "0008 (member-AND P2PDMA gating) must be SKIPPED on bare upstream" ;;
esac
case "$tb_out" in
	*"Skipping 0009-"*) : ;;
	*) dkms_fail "0009 (meshstor raid variant) must be SKIPPED on bare upstream" ;;
esac
case "$tb_out" in
	*"Applying 0010-"*) : ;;
	*) dkms_fail "0010 (upstream raid variant) must be APPLIED on bare upstream" ;;
esac

# --- 3. no meshstor-only p2pdma feature leaked into the baseline ----------
# Re-keyed 2026-07-29 (v6 rework): this used to also assert that ms.h lacked
# ms_bio_is_p2pdma (md_bio_is_p2pdma pre-rename), on the theory that helper
# was meshstor-only. It is not, any more: upstream's v6 P2PDMA series
# upstreams md_bio_is_p2pdma itself, so once v6 merges, even a genuine bare-
# upstream `master` carries it (renamed to ms_bio_is_p2pdma same as anywhere
# else) and that assertion would break the discriminator it was meant to
# protect. raid1_can_advertise_p2pdma(), the p2pdma_advertise knob, and the
# p2pdma_status report are meshstor value-adds with NO upstream counterpart
# (see docs/superpowers/specs/2026-07-29-p2pdma-v6-rework-design.md §3.4) --
# tokens that stay meshstor-only permanently, unlike md_bio_is_p2pdma. Keying
# on those instead means this assertion survives v6 merging upstream.
assert_file_not_matches "$OUT/raid1-10_ms.c" 'raid1_can_advertise_p2pdma' \
	"baseline must NOT carry the member-AND helper"
assert_file_not_matches "$OUT/ms.c" 'p2pdma_status_show|p2pdma_advertise' \
	"baseline must NOT carry the meshstor-only p2pdma_advertise knob or p2pdma_status report (no upstream counterpart)"

# --- 4. both upstream lim.features touches are gated together, pre-stack ----
for f in raid1_ms.c raid10_ms.c; do
	# exactly one of each assignment, both present
	[ "$(grep -c 'lim.features |= BLK_FEAT_ATOMIC_WRITES' "$OUT/$f")" = "1" ] \
		|| dkms_fail "$f must have exactly one ATOMIC_WRITES assignment"
	[ "$(grep -c 'lim.features |= BLK_FEAT_PCI_P2PDMA' "$OUT/$f")" = "1" ] \
		|| dkms_fail "$f must have exactly one (gated) PCI_P2PDMA assignment"
	# both sit inside ONE #ifdef HAVE_QUEUE_LIMITS_FEATURES block that precedes
	# the stack call: between the #ifdef and the next #endif, both flags appear.
	block="$(awk '/#ifdef HAVE_QUEUE_LIMITS_FEATURES/{f=1} f{print} /#endif/{if(f)exit}' "$OUT/$f")"
	case "$block" in
		*BLK_FEAT_ATOMIC_WRITES*BLK_FEAT_PCI_P2PDMA*) : ;;
		*) dkms_fail "$f: ATOMIC_WRITES and PCI_P2PDMA must share one HAVE_QUEUE_LIMITS_FEATURES block" ;;
	esac
	# the gated block must come BEFORE the stack call (upstream order)
	awk '/lim.features \|= BLK_FEAT_PCI_P2PDMA/{p=NR} /_stack_rdev_limits/{s=NR} END{exit !(p && s && p < s)}' \
		"$OUT/$f" || dkms_fail "$f: gated P2PDMA must precede mddev_stack_rdev_limits (upstream placement)"
done

# --- 5. it compiles as kernel modules from the bare-upstream source --------
if ! mk_out="$(make -C "$OUT" KDIR="$KDIR" -j"$(nproc)" 2>&1)"; then
	echo "FAIL: bare-upstream baseline module build failed" >&2
	echo "$mk_out" | tail -40 >&2
	exit 1
fi
for ko in ms_mod.ko raid1_ms.ko raid10_ms.ko; do
	[ -f "$OUT/$ko" ] || dkms_fail "expected module not built: $ko"
done

dkms_pass "bare-upstream baseline: .when guards select 0010, the two lim.features touches are gated together pre-stack, no feature leak, and ms_mod/raid1_ms/raid10_ms compile"
