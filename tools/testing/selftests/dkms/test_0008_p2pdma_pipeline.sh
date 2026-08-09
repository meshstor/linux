#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
#
# End-to-end test for the P2PDMA / GPUDirect-Storage feature (v6 rework). The
# feature lives in drivers/md (feature branch `p2pdma`, rebuilt on upstream's
# v6 P2PDMA completion-handling series); dkms/patches/0008 gates the
# advertise/knob/status surface for pre-6.11, dkms/patches/0012 synthesises
# BLK_STS_P2PDMA on kernels that cannot emit it natively. Runs the REAL
# assembly pipeline -- bin/build-tarball (patch -p1, the md_*->ms_* rename
# pass, template render) -- then compiles the result as kernel modules
# against the running kernel, and asserts the feature both survived the
# rename and is correctly capability-gated.
#
# SUPERSEDES the pre-2026-07-29 version of this test, which asserted the old
# "stage-1 fail-the-write" design (R1BIO_P2PError/R10BIO_P2PError state bits,
# raid1_p2pdma_clear_on_add(), a completion arm that failed the whole write
# loud with no badblocks recorded). That design was replaced by the v6
# rework: a P2P-tagged completion that cannot route is now recorded as a
# BAD BLOCK, the member is NOT faulted, WantReplacement is NOT set, and the
# MASTER WRITE SUCCEEDS off the surviving leg -- matching upstream's own
# raid1_write_error()/handle_write_finished() handling. Only past ~512
# badblock entries does rdev_set_badblocks() itself fault the member and
# degrade the array (loud in dmesg/msstat, silent to the application). This
# file's assertions were rewritten from scratch against that shape; nothing
# here should be read as carrying forward any assumption from the old test.
#
# What it proves:
#   * the advertise gate (raid1_can_advertise_p2pdma), the
#     p2pdma_advertise=auto|always|never module knob, and the per-array
#     p2pdma_status sysfs report all survive the rename
#     (mddev -> mssev, md_* -> ms_*) while kernel tokens
#     (BLK_FEAT_PCI_P2PDMA, BLK_STS_P2PDMA, BLK_STS_INVAL/TARGET) are NOT
#     mangled by it;
#   * that whole surface is #ifdef HAVE_BLK_FEAT_PCI_P2PDMA gated, so it
#     compiles out on kernels without the capability;
#   * dkms/patches/0012's BLK_STS_P2PDMA compat synthesis -- the R1BIO_P2PDMA/
#     R10BIO_P2PDMA tag, the inbound INVAL/TARGET->P2PDMA translation, the
#     outbound IOERR clamp, and the tag-gated badblock dispatch -- survives
#     the rename and is gated `#if defined(HAVE_BLK_FEAT_PCI_P2PDMA) &&
#     !defined(HAVE_BLK_STS_P2PDMA)` (never fires on a kernel that already
#     has the native status);
#   * raid1_write_error() returns for a P2PDMA-tagged completion BEFORE
#     WantReplacement is set or a failfast md_error() can fire -- the
#     no-fault, no-replacement invariant the whole design rests on -- and
#     this holds regardless of HAVE_BLK_STS_P2PDMA (it is upstream's own,
#     ungated completion handling, not part of the compat synthesis);
#   * ms_mod/raid1_ms/raid10_ms link with the feature present.
#
# Needs a kernel source tree that actually carries drivers/md (this harness
# branch does not). Discovery order: $KERNEL_TREE -> build/linux-meshstor-rebuilt
# -> the existing .worktrees/p2pdma checkout (read-only; never modified here)
# -> a temp worktree of the local `p2pdma` branch. SKIPs (exit 4) if none is
# available or the toolchain/kernel-build tree is missing.

set -u
# shellcheck source=tools/testing/selftests/dkms/lib.sh
. "$(dirname "$0")/lib.sh"

VER="0.0.0-selftest-p2pdma"
KDIR="${KDIR:-/lib/modules/$(uname -r)/build}"
OUT="$REPO_ROOT/build/meshstor-ms-$VER"
TARBALL="$REPO_ROOT/build/meshstor-ms-$VER.dkms.tar.gz"
WORKTREE=""   # set only if we create a throwaway p2pdma worktree ourselves

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

# --- locate a kernel tree that carries drivers/md -----------------------
# (after the eager cleanup, so creating the worktree below isn't undone)
has_md() { [ -f "$1/drivers/md/raid1.c" ] && [ -f "$1/drivers/md/md.c" ]; }
# The v6-rework advertise gate lives in drivers/md on the `p2pdma` branch;
# only accept a tree that actually carries it. A plain master / rebuilt-
# without-p2pdma tree still has upstream's unconditional advertise and would
# fail every assertion below.
has_feature() { grep -q 'raid1_can_advertise_p2pdma' "$1/drivers/md/raid1-10.c" 2>/dev/null; }
KT=""
if [ -n "${KERNEL_TREE:-}" ] && has_md "$KERNEL_TREE" && has_feature "$KERNEL_TREE"; then
	KT="$KERNEL_TREE"
elif has_md "$REPO_ROOT/build/linux-meshstor-rebuilt" && has_feature "$REPO_ROOT/build/linux-meshstor-rebuilt"; then
	KT="$REPO_ROOT/build/linux-meshstor-rebuilt"
elif has_md "$REPO_ROOT/.worktrees/p2pdma" && has_feature "$REPO_ROOT/.worktrees/p2pdma"; then
	KT="$REPO_ROOT/.worktrees/p2pdma"   # pre-existing, read-only; never modified
elif git -C "$REPO_ROOT" rev-parse --verify -q p2pdma >/dev/null; then
	WORKTREE="$(dkms_mktemp_dir)/ktree"
	if ! git -C "$REPO_ROOT" worktree add --detach "$WORKTREE" p2pdma >/dev/null 2>&1; then
		dkms_skip "could not create p2pdma worktree for drivers/md sources"
	fi
	has_md "$WORKTREE" || dkms_skip "p2pdma worktree lacks drivers/md"
	KT="$WORKTREE"
else
	dkms_skip "no kernel tree with drivers/md (set KERNEL_TREE=, run bin/rebuild-main, or provide the p2pdma branch)"
fi

# --- 1. assemble via the production pipeline (compat patches + rename) ------
if ! tb_out="$(KERNEL_TREE="$KT" KDIR="$KDIR" \
		bash "$REPO_ROOT/bin/build-tarball" "$VER" 2>&1)"; then
	echo "FAIL: bin/build-tarball failed (0008/0012 may not apply -- is $KT a v6-reworked p2pdma tree?)" >&2
	echo "$tb_out" | tail -30 >&2
	exit 1
fi
[ -d "$OUT" ] || dkms_fail "build-tarball did not produce $OUT"

# --- 2. feature survived the rename, in the RENAMED (ms_*) sources -------
# core: helper renamed, REQ_NOMERGE preserved for P2P bios
assert_file_matches "$OUT/ms.h" 'static inline bool ms_bio_is_p2pdma' \
	"md_bio_is_p2pdma must survive the rename into ms.h as ms_bio_is_p2pdma"
assert_file_matches "$OUT/ms.h" 'is_pci_p2pdma_page' \
	"ms_bio_is_p2pdma must still reference the kernel token is_pci_p2pdma_page (must not be rename-mangled)"
assert_file_matches "$OUT/ms.c" 'ms_bio_is_p2pdma\(bio\)' \
	"ms_submit_bio must guard the REQ_NOMERGE handling on ms_bio_is_p2pdma"

# --- 3. per-member advertise gate (task 3/4/5's surface) -----------------
assert_file_matches "$OUT/raid1-10_ms.c" 'static bool raid1_can_advertise_p2pdma\(struct mssev' \
	"the member-AND advertise helper must survive the rename (mddev -> mssev) in raid1-10_ms.c"
assert_file_matches "$OUT/raid1-10_ms.c" 'p2pdma_advertise == 1' \
	"the always-override branch of raid1_can_advertise_p2pdma must survive"
assert_file_matches "$OUT/raid1-10_ms.c" 'p2pdma_advertise == 2' \
	"the never-override branch of raid1_can_advertise_p2pdma must survive"
assert_file_not_matches "$OUT/raid1-10_ms.c" 'raid1_p2pdma_clear_on_add' \
	"the retired raid1_p2pdma_clear_on_add() name must not reappear (superseded by raid1_p2pdma_reeval_on_change())"
assert_file_matches "$OUT/raid1-10_ms.c" 'raid1_p2pdma_reeval_on_change\(struct mssev' \
	"the hot-add/remove re-evaluation helper must survive the rename"
for f in raid1_ms.c raid10_ms.c; do
	adv=$(grep -c 'lim\.features |= BLK_FEAT_PCI_P2PDMA' "$OUT/$f" || true)
	[ "$adv" = "1" ] || dkms_fail "$f must have exactly one BLK_FEAT_PCI_P2PDMA advertise (found $adv)"
	assert_file_matches "$OUT/$f" 'raid1_can_advertise_p2pdma\(mssev\)' \
		"$f must call the shared advertise gate"
	reeval=$(grep -c 'raid1_p2pdma_reeval_on_change' "$OUT/$f" || true)
	[ "$reeval" -ge 3 ] || dkms_fail "$f must call raid1_p2pdma_reeval_on_change at its add/remove sites (found $reeval, want >= 3)"
done
# the whole advertise/knob/status surface is #ifdef-gated; kernel tokens
# (BLK_FEAT_PCI_P2PDMA) must not have been renamed (no md_/MD_ substring)
assert_file_matches "$OUT/raid1_ms.c" '#ifdef HAVE_BLK_FEAT_PCI_P2PDMA' \
	"the raid1 advertise block must be gated on HAVE_BLK_FEAT_PCI_P2PDMA"
assert_file_not_matches "$OUT/raid1_ms.c" 'BLK_FEAT_PCI_P2PDMA.*MS_\|HAVE_BLK_FEAT_PCI_P2PMS' \
	"the P2PDMA capability tokens must not be corrupted by the md_*->ms_* rename"

# --- 4. the p2pdma_advertise module knob (task 4) ------------------------
assert_file_matches "$OUT/ms.h" 'extern int p2pdma_advertise;' \
	"the p2pdma_advertise extern must survive in ms.h"
assert_file_matches "$OUT/ms.c" 'int p2pdma_advertise = MS_P2PDMA_ADVERTISE_AUTO;' \
	"the p2pdma_advertise definition and its MD_->MS_ renamed default enum literal must survive"
assert_file_matches "$OUT/ms.c" 'EXPORT_SYMBOL_GPL\(p2pdma_advertise\);' \
	"p2pdma_advertise must stay exported"
assert_file_matches "$OUT/ms.c" 'module_param_cb\(p2pdma_advertise,' \
	"the module_param_cb wiring must survive"
assert_file_matches "$OUT/ms.c" '"auto"' \
	"the auto/always/never policy name table must survive"

# --- 5. the p2pdma_status per-array report (task 6/10) -------------------
assert_file_matches "$OUT/ms.c" 'p2pdma_status_show' \
	"p2pdma_status_show must survive the rename"
assert_file_matches "$OUT/ms.c" '"array advertise=%s policy=%s\\n"' \
	"the array-level p2pdma_status line format must survive"
assert_file_matches "$OUT/ms.c" '__ATTR\(p2pdma_status, S_IRUGO, p2pdma_status_show, NULL\)' \
	"the ms_p2pdma_status sysfs entry must survive"
assert_file_matches "$OUT/ms.c" '&ms_p2pdma_status\.attr,' \
	"p2pdma_status must be wired into the renamed ms_redundancy_attrs[] table"

# --- 6. dkms/patches/0012's BLK_STS_P2PDMA compat synthesis --------------
# The R1BIO_P2PDMA/R10BIO_P2PDMA state bits carry no md_/MD_ substring, so
# the rename pass must leave them byte-identical in the renamed headers/sources.
assert_file_matches "$OUT/raid1_ms.h" 'R1BIO_P2PDMA' \
	"R1BIO_P2PDMA state bit must survive the rename un-mangled in raid1_ms.h"
assert_file_matches "$OUT/raid10_ms.h" 'R10BIO_P2PDMA' \
	"R10BIO_P2PDMA state bit must survive the rename un-mangled in raid10_ms.h"
assert_file_matches "$OUT/raid1_ms.c" 'BLK_STS_TARGET' \
	"raid1's inbound translation must still match the kernel token BLK_STS_TARGET"
assert_file_matches "$OUT/raid10_ms.c" 'BLK_STS_TARGET' \
	"raid10's inbound translation must still match the kernel token BLK_STS_TARGET"

# assert_gated FILE EXTENDED_REGEX MESSAGE -- the pattern must appear in FILE
# and EVERY non-preprocessor occurrence must sit inside a
# `#if defined(HAVE_BLK_FEAT_PCI_P2PDMA) && !defined(HAVE_BLK_STS_P2PDMA)`
# span OR a `#ifdef MS_P2P_ROUTE_FENCE_KERNEL` span -- compat.h defines
# that macro under the same two conditions plus the graft signature, so
# it is a strict subset of 0012's gate (0013's fence hooks live there).
# A span's #else or matching #endif ends it; nested #if levels are
# tracked.
assert_gated() {
	awk -v rx="$2" '
		/^[ \t]*#[ \t]*if/    { st[++sp] = /#[ \t]*if[ \t]+defined\(HAVE_BLK_FEAT_PCI_P2PDMA\)[ \t]*&&[ \t]*![ \t]*defined\(HAVE_BLK_STS_P2PDMA\)/ \
		                                 || /#[ \t]*ifdef[ \t]+MS_P2P_ROUTE_FENCE_KERNEL/ }
		/^[ \t]*#[ \t]*else/  { if (sp) st[sp] = 0 }
		/^[ \t]*#[ \t]*endif/ { if (sp) sp-- }
		$0 ~ rx && $0 !~ /^[ \t]*#/ {
			g = 0; for (i = 1; i <= sp; i++) if (st[i]) g = 1
			if (g) found = 1; else bad = 1
		}
		END { exit !(found && !bad) }
	' "$1" || dkms_fail "$3"
}
for f in raid1_ms.c raid10_ms.c; do
	tag=$([ "$f" = raid1_ms.c ] && echo R1BIO_P2PDMA || echo R10BIO_P2PDMA)
	n=$(grep -c '#if defined(HAVE_BLK_FEAT_PCI_P2PDMA) && !defined(HAVE_BLK_STS_P2PDMA)' "$OUT/$f" || true)
	[ "$n" = "7" ] || dkms_fail "$f must have exactly 7 !HAVE_BLK_STS_P2PDMA compat sites (tag x2, inbound translation x2, outbound clamp, narrow_write_error check, tag-gated dispatch) — found $n"
	assert_gated "$OUT/$f" "$tag" \
		"every $f $tag reference must be inside a !HAVE_BLK_STS_P2PDMA compat region"
done
for f in raid1_ms.h raid10_ms.h; do
	n=$(grep -c '#if defined(HAVE_BLK_FEAT_PCI_P2PDMA) && !defined(HAVE_BLK_STS_P2PDMA)' "$OUT/$f" || true)
	[ "$n" = "1" ] || dkms_fail "$f must have exactly one !HAVE_BLK_STS_P2PDMA compat site (the state-bit definition) — found $n"
done
# the outbound clamp: a residual BLK_STS_P2PDMA on the master bio must
# become BLK_STS_IOERR before bio_endio(), on both personalities
assert_file_matches "$OUT/raid1_ms.c" 'bio->bi_status = BLK_STS_IOERR;' \
	"raid1's outbound clamp (master bio) must rewrite a residual BLK_STS_P2PDMA to BLK_STS_IOERR"
assert_file_matches "$OUT/raid10_ms.c" 'bio->bi_status = BLK_STS_IOERR;' \
	"raid10's outbound clamp (master bio) must rewrite a residual BLK_STS_P2PDMA to BLK_STS_IOERR"

# --- 7. THE headline behavioral invariant: badblock + continue, NOT fail-the-write
# raid1_write_error() must return for a P2PDMA-tagged completion strictly
# BEFORE WantReplacement can be set or a failfast md_error() can fire. This
# is upstream's OWN v6 completion handling (task 2's patches), present on
# every kernel regardless of HAVE_BLK_STS_P2PDMA -- NOT part of the 0012
# compat gate -- so it is asserted ungated. This is the exact opposite of
# the retired design: no fault, no WantReplacement, no loud EINVAL to the
# submitter; the range is fenced as a badblock elsewhere
# (handle_write_finished, asserted in section 6 above) and the master write
# succeeds off the surviving leg.
assert_no_fault_before_replacement() {  # FILE FUNCSIG STATUSCONST MESSAGE
	awk -v fn="$2" -v st="$3" '
		index($0, fn) { f = 1 }
		f && index($0, "bi_status == " st) { p = NR }
		f && index($0, "WantReplacement") { w = NR }
		f && /^}/ { exit }
		END { exit !(p && w && p < w) }
	' "$1" || dkms_fail "$4"
}
assert_no_fault_before_replacement "$OUT/raid1-10_ms.c" "raid1_write_error(" "BLK_STS_P2PDMA" \
	"raid1_write_error(): the BLK_STS_P2PDMA early-return must precede the WantReplacement/failfast path (no-fault invariant)"

# --- 8. it compiles as kernel modules with the feature present ----------
if ! mk_out="$(make -C "$OUT" KDIR="$KDIR" -j"$(nproc)" 2>&1)"; then
	echo "FAIL: module build failed with P2PDMA feature" >&2
	echo "$mk_out" | tail -40 >&2
	exit 1
fi
for ko in ms_mod.ko raid1_ms.ko raid10_ms.ko; do
	[ -f "$OUT/$ko" ] || dkms_fail "expected module not built: $ko"
done

# --- 9. the build's feature_flags.h actually enabled the feature --------
assert_file_matches "$OUT/compat/feature_flags.h" 'HAVE_BLK_FEAT_PCI_P2PDMA 1' \
	"the build must have detected HAVE_BLK_FEAT_PCI_P2PDMA on this kernel"

dkms_pass "P2PDMA v6 rework (advertise gate + knob + status + BLK_STS_P2PDMA compat synthesis) survives rename, is capability-gated, badblocks-and-continues rather than failing the write, and compiles (ms_mod/raid1_ms/raid10_ms)"
