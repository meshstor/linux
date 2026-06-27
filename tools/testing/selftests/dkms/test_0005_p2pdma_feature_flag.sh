#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
#
# P2PDMA (GPUDirect Storage) capability gating.
#
# The md array's request_queue does not advertise BLK_FEAT_PCI_P2PDMA, and that
# flag is deliberately excluded from BLK_FEAT_INHERIT_MASK, so it never
# propagates up from member NVMe devices. A meshstor fork that wants real GDS
# must set it explicitly in raid1_set_limits() — but only on kernels that have
# the modern queue_limits.features form of the flag. On kernels without it
# (e.g. RHEL9/5.14, which also lack the FOLL_PCI_P2PDMA O_DIRECT path merged in
# mainline v6.2) the feature must compile out cleanly.
#
# This pins the gating contract so the feature code can rely on it:
#   1. dkms/Makefile.in's feature_flags target defines HAVE_BLK_FEAT_PCI_P2PDMA
#      iff <linux/blkdev.h> carries the BLK_FEAT_PCI_P2PDMA symbol.
#   2. dkms/compat/compat.h neutralises a bare `|= BLK_FEAT_PCI_P2PDMA` to a
#      no-op (define to 0) when the flag is absent, so the OR compiles anywhere.
#
# SKIPs are not expected here (no kernel build needed) — it exercises the
# detector against synthetic header fixtures, like test_0003.

set -u
# shellcheck source=tools/testing/selftests/dkms/lib.sh
. "$(dirname "$0")/lib.sh"

FLAG="HAVE_BLK_FEAT_PCI_P2PDMA"
COMPAT="$REPO_ROOT/dkms/compat/compat.h"

[ -f "$COMPAT" ] || dkms_fail "compat.h not found at $COMPAT"

# --- 1. flag DEFINED when blkdev.h has the modern feature bit ------------
kdir_present="$(dkms_make_kdir)"
cat > "$kdir_present/include/linux/blkdev.h" <<'EOF'
/* modern (~6.11+) form: the P2PDMA capability lives in queue_limits.features */
#define BLK_FEAT_PCI_P2PDMA	((__force blk_features_t)(1u << 12))
#define blk_queue_pci_p2pdma(q)	((q)->limits.features & BLK_FEAT_PCI_P2PDMA)
EOF
ff="$(dkms_run_feature_flags "$kdir_present")" \
	|| dkms_fail "feature_flags run failed (flag-present fixture)"
assert_file_matches "$ff" "#define[[:space:]]+${FLAG}[[:space:]]+1" \
	"feature_flags must define $FLAG when blkdev.h has BLK_FEAT_PCI_P2PDMA"

# --- 2. flag NOT defined on the legacy queue_flag form (pre-6.11) --------
# 5.14-era blkdev.h has only the old QUEUE_FLAG_PCI_P2PDMA spelling and the
# accessor checks queue_flags, never the BLK_FEAT_ token. Must NOT trigger.
kdir_legacy="$(dkms_make_kdir)"
cat > "$kdir_legacy/include/linux/blkdev.h" <<'EOF'
/* legacy form: a queue_flags bit, no queue_limits.features, no BLK_FEAT_ enum */
#define QUEUE_FLAG_PCI_P2PDMA	25
#define blk_queue_pci_p2pdma(q)	test_bit(QUEUE_FLAG_PCI_P2PDMA, &(q)->queue_flags)
EOF
ff="$(dkms_run_feature_flags "$kdir_legacy")" \
	|| dkms_fail "feature_flags run failed (legacy fixture)"
assert_file_not_matches "$ff" "$FLAG" \
	"feature_flags must NOT define $FLAG on the legacy QUEUE_FLAG_PCI_P2PDMA form"

# --- 3. compat.h neutralises a bare OR when the flag is absent -----------
assert_file_matches "$COMPAT" "#ifndef[[:space:]]+$FLAG" \
	"compat.h must guard the BLK_FEAT_PCI_P2PDMA fallback on #ifndef $FLAG"
assert_file_matches "$COMPAT" "#define[[:space:]]+BLK_FEAT_PCI_P2PDMA[[:space:]]+0" \
	"compat.h must define BLK_FEAT_PCI_P2PDMA to 0 when the kernel lacks it (no-op OR)"

dkms_pass "P2PDMA capability gating: detector is form-aware and compat fallback is present"
