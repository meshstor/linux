#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
#
# End-to-end test for the P2PDMA / GPUDirect-Storage feature. The feature lives in
# drivers/md (feature branch p2pdma-fixes); dkms/patches/0008-p2pdma-feature-flag-
# gating.patch gates it for pre-6.11. Runs the REAL assembly pipeline — bin/build-tarball (patch -p1,
# the md_*->ms_* rename pass, template render) — then compiles the result as
# kernel modules against the running kernel, and asserts the feature both
# survived the rename and is correctly capability-gated.
#
# What it proves:
#   * the feature (from p2pdma-fixes) + the 0008 gating patch survive the pipeline;
#   * the new code survives the rename (md_bio_is_p2pdma -> ms_bio_is_p2pdma,
#     struct mddev -> mssev on raid1_can_advertise_p2pdma), while the kernel
#     tokens BLK_FEAT_PCI_P2PDMA / is_pci_p2pdma_page are NOT mangled;
#   * everything is wrapped in #ifdef HAVE_BLK_FEAT_PCI_P2PDMA so it compiles
#     out on kernels without the capability;
#   * ms_mod/raid1_ms/raid10_ms link with the feature present.
#
# Needs a kernel source tree that actually carries drivers/md (this harness
# branch does not). Discovery order: $KERNEL_TREE -> build/linux-meshstor-rebuilt
# -> a temp worktree of the local p2pdma-fixes branch. SKIPs (exit 4) if none
# is available or the toolchain/kernel-build tree is missing.

set -u
# shellcheck source=tools/testing/selftests/dkms/lib.sh
. "$(dirname "$0")/lib.sh"

VER="0.0.0-selftest-p2pdma"
KDIR="${KDIR:-/lib/modules/$(uname -r)/build}"
OUT="$REPO_ROOT/build/meshstor-ms-$VER"
TARBALL="$REPO_ROOT/build/meshstor-ms-$VER.dkms.tar.gz"
WORKTREE=""   # set if we create a throwaway p2pdma-fixes worktree

# --- preconditions: missing toolchain/kernel tree is a SKIP -------------
command -v make >/dev/null 2>&1 || dkms_skip "make not available"
command -v gcc  >/dev/null 2>&1 || dkms_skip "gcc not available"
[ -d "$KDIR" ]          || dkms_skip "kernel build tree not found: $KDIR"
[ -f "$KDIR/Makefile" ] || dkms_skip "kernel build tree incomplete: $KDIR"

# The feature only exists on kernels with the modern queue_limits P2PDMA flag;
# on older ones it compiles out and there is nothing meaningful to assert here.
grep -q 'BLK_FEAT_PCI_P2PDMA' "$KDIR/include/linux/blkdev.h" 2>/dev/null \
	|| dkms_skip "running kernel lacks BLK_FEAT_PCI_P2PDMA (feature compiles out; nothing to assert)"

p2pdma_cleanup() {
	rm -rf "$OUT" "$TARBALL"
	[ -n "$WORKTREE" ] && git -C "$REPO_ROOT" worktree remove --force "$WORKTREE" >/dev/null 2>&1
	return 0
}
trap 'p2pdma_cleanup; dkms_cleanup' EXIT
p2pdma_cleanup   # clear stale artifacts (WORKTREE still empty here)

# --- locate a kernel tree that carries drivers/md ----------------------
# (after the eager cleanup, so creating the worktree below isn't undone)
has_md() { [ -f "$1/drivers/md/raid1.c" ] && [ -f "$1/drivers/md/md.c" ]; }
# The P2P feature lives in drivers/md on the p2pdma-fixes branch; only accept a
# tree that actually carries it. A plain master / rebuilt-without-p2pdma-fixes
# tree still has upstream's unconditional advertise and would fail 0005/0008.
has_feature() { grep -q 'raid1_can_advertise_p2pdma' "$1/drivers/md/raid1-10.c" 2>/dev/null; }
KT=""
if [ -n "${KERNEL_TREE:-}" ] && has_md "$KERNEL_TREE" && has_feature "$KERNEL_TREE"; then
	KT="$KERNEL_TREE"
elif has_md "$REPO_ROOT/build/linux-meshstor-rebuilt" && has_feature "$REPO_ROOT/build/linux-meshstor-rebuilt"; then
	KT="$REPO_ROOT/build/linux-meshstor-rebuilt"
elif git -C "$REPO_ROOT" rev-parse --verify -q p2pdma-fixes >/dev/null; then
	WORKTREE="$(dkms_mktemp_dir)/ktree"
	if ! git -C "$REPO_ROOT" worktree add --detach "$WORKTREE" p2pdma-fixes >/dev/null 2>&1; then
		dkms_skip "could not create p2pdma-fixes worktree for drivers/md sources"
	fi
	has_md "$WORKTREE" || dkms_skip "p2pdma-fixes worktree lacks drivers/md"
	KT="$WORKTREE"
else
	dkms_skip "no kernel tree with drivers/md (set KERNEL_TREE=, run bin/rebuild-main, or provide p2pdma-fixes)"
fi

# --- 1. assemble via the production pipeline (compat patches + rename) ------
if ! tb_out="$(KERNEL_TREE="$KT" KDIR="$KDIR" \
		bash "$REPO_ROOT/bin/build-tarball" "$VER" 2>&1)"; then
	echo "FAIL: bin/build-tarball failed (0008 gating patch may not apply -- is $KT a p2pdma-fixes tree?)" >&2
	echo "$tb_out" | tail -30 >&2
	exit 1
fi
[ -d "$OUT" ] || dkms_fail "build-tarball did not produce $OUT"

# --- 2. feature survived the rename, in the RENAMED (ms_*) sources -------
# core: helper renamed, REQ_NOMERGE preserved for P2P bios
assert_file_matches "$OUT/ms.h" 'static inline bool ms_bio_is_p2pdma' \
	"md_bio_is_p2pdma must survive the rename into ms.h as ms_bio_is_p2pdma"
assert_file_matches "$OUT/ms.c" 'if \(!ms_bio_is_p2pdma\(bio\)\)' \
	"md_submit_bio must guard the REQ_NOMERGE clear on ms_bio_is_p2pdma"
# --- raid1: exactly ONE gated advertise, no bare/adjacent line ----------
adv_count=$(grep -c 'lim\.features |= BLK_FEAT_PCI_P2PDMA' "$OUT/raid1_ms.c" || true)
[ "$adv_count" = "1" ] || dkms_fail "raid1_ms.c must have exactly one BLK_FEAT_PCI_P2PDMA advertise (found $adv_count)"
assert_file_matches "$OUT/raid1_ms.c" '#ifdef HAVE_BLK_FEAT_PCI_P2PDMA' \
	"raid1 advertise must be #ifdef-gated"
# nothing but 0005's #endif may sit between ATOMIC_WRITES and the stack call:
# the advertise belongs AFTER it, #ifdef-gated. (0005 wraps ATOMIC_WRITES in
# #ifdef HAVE_QUEUE_LIMITS_FEATURES, so its #endif -- never a bare PCI_P2PDMA --
# is the line that immediately follows; `_stack_rdev_limits` survives the rename.)
awk '/lim\.features \|= BLK_FEAT_ATOMIC_WRITES/{f=1; next} /_stack_rdev_limits/{f=0} f' \
	"$OUT/raid1_ms.c" | grep -q 'BLK_FEAT_PCI_P2PDMA' \
	&& dkms_fail "raid1: bare BLK_FEAT_PCI_P2PDMA still sits between ATOMIC_WRITES and the stack call"
# helper DEFINITION now lives in the shared file, not raid1_ms.c
assert_file_matches "$OUT/raid1-10_ms.c" 'raid1_can_advertise_p2pdma\(struct mssev' \
	"the member-AND helper definition must be in raid1-10_ms.c after the move"
# --- raid10: gated advertise was ADDED (not just bare-line deleted) ------
adv10=$(grep -c 'lim\.features |= BLK_FEAT_PCI_P2PDMA' "$OUT/raid10_ms.c" || true)
[ "$adv10" = "1" ] || dkms_fail "raid10_ms.c must have exactly one gated advertise (found $adv10)"
assert_file_matches "$OUT/raid10_ms.c" 'raid1_can_advertise_p2pdma\(mssev\)' \
	"raid10 must call the shared advertise gate"
# --- write-behind skip survives, on the ORIGINAL bio helper -------------
assert_file_matches "$OUT/raid1_ms.c" '!ms_bio_is_p2pdma\(bio\)' \
	"raid1 write-behind must skip P2P bios"
# An experimental raid1_should_handle_error P2P special-case was dropped from the
# feature branch: it stays upstream, with no is_pci_p2pdma_page check there.
assert_file_not_matches "$OUT/raid1-10_ms.c" 'is_pci_p2pdma_page' \
	"raid1_should_handle_error must carry NO P2P change"
# base must NOT contain the deferred error-path/self-heal code (separate checks,
# regex-dialect-agnostic):
assert_file_not_matches "$OUT/raid1_ms.c" 'R1BIO_P2P' \
	"base raid1 must not carry the deferred R1BIO_P2P/P2PError state"
assert_file_not_matches "$OUT/raid1_ms.c" 'dirty_bits' \
	"base must not carry the deferred self-heal dirty_bits call"
# is_pci_p2pdma_page is NOT orphaned -- ms.h still uses it via ms_bio_is_p2pdma:
assert_file_matches "$OUT/ms.h" 'is_pci_p2pdma_page' \
	"ms_bio_is_p2pdma must still reference is_pci_p2pdma_page"

# --- 3. capability-gated so it compiles out on kernels without P2PDMA ----
# Every feature site sits under #ifdef HAVE_BLK_FEAT_PCI_P2PDMA. The kernel
# tokens must NOT have been renamed (no md_/MD_ substring), or compile breaks.
assert_file_matches "$OUT/raid1_ms.c" '#ifdef HAVE_BLK_FEAT_PCI_P2PDMA' \
	"the raid1 advertise block must be gated on HAVE_BLK_FEAT_PCI_P2PDMA"
assert_file_not_matches "$OUT/raid1_ms.c" 'BLK_FEAT_PCI_P2PDMA.*MS_\|HAVE_BLK_FEAT_PCI_P2PMS' \
	"the P2PDMA capability tokens must not be corrupted by the md_*->ms_* rename"

# --- 4. it compiles as kernel modules with the feature present ----------
if ! mk_out="$(make -C "$OUT" KDIR="$KDIR" -j"$(nproc)" 2>&1)"; then
	echo "FAIL: module build failed with P2PDMA feature" >&2
	echo "$mk_out" | tail -40 >&2
	exit 1
fi
for ko in ms_mod.ko raid1_ms.ko raid10_ms.ko; do
	[ -f "$OUT/$ko" ] || dkms_fail "expected module not built: $ko"
done

# --- 5. the build's feature_flags.h actually enabled the feature --------
assert_file_matches "$OUT/compat/feature_flags.h" 'HAVE_BLK_FEAT_PCI_P2PDMA 1' \
	"the build must have detected HAVE_BLK_FEAT_PCI_P2PDMA on this kernel"

dkms_pass "P2PDMA feature (p2pdma-fixes md source + 0008 gating patch) survives rename, is capability-gated, and compiles (ms_mod/raid1_ms/raid10_ms)"
