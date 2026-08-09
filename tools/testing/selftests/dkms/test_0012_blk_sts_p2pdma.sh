#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
#
# BLK_STS_P2PDMA compat gating.
#
# Upstream v6 patch 1 adds BLK_STS_P2PDMA = 18 to <linux/blk_types.h>. Every
# kernel we ship to (6.12 .. 7.2-rc) predates it, but v6 patches 7 and 8
# reference the constant in ordinary C, so the packaged sources do not COMPILE
# without a definition. dkms/compat/compat.h supplies one, gated so a kernel
# that has the real thing always wins.
#
# Value 18 is deliberate: it is upstream's, and it is unused on every target,
# so a member driver that emits it (our patched nvme-rdma) and md agree.
set -u
# shellcheck source=tools/testing/selftests/dkms/lib.sh
. "$(dirname "$0")/lib.sh"

FLAG="HAVE_BLK_STS_P2PDMA"
COMPAT="$REPO_ROOT/dkms/compat/compat.h"

[ -f "$COMPAT" ] || dkms_fail "compat.h not found at $COMPAT"

# --- 1. flag DEFINED when blk_types.h already carries the status ---------
kdir_present="$(dkms_make_kdir)"
cat > "$kdir_present/include/linux/blk_types.h" <<'EOF'
#define BLK_STS_DURATION_LIMIT	((__force blk_status_t)17)
#define BLK_STS_P2PDMA		((__force blk_status_t)18)
#define BLK_STS_INVAL		((__force blk_status_t)19)
EOF
ff="$(dkms_run_feature_flags "$kdir_present")" \
	|| dkms_fail "feature_flags run failed (status-present fixture)"
assert_file_matches "$ff" "#define[[:space:]]+${FLAG}[[:space:]]+1" \
	"feature_flags must define $FLAG when blk_types.h has BLK_STS_P2PDMA"

# --- 2. flag NOT defined on every kernel we actually ship to -------------
kdir_absent="$(dkms_make_kdir)"
cat > "$kdir_absent/include/linux/blk_types.h" <<'EOF'
#define BLK_STS_DURATION_LIMIT	((__force blk_status_t)17)
#define BLK_STS_INVAL		((__force blk_status_t)19)
EOF
ff="$(dkms_run_feature_flags "$kdir_absent")" \
	|| dkms_fail "feature_flags run failed (status-absent fixture)"
assert_file_not_matches "$ff" "$FLAG" \
	"feature_flags must NOT define $FLAG when blk_types.h lacks BLK_STS_P2PDMA"

# --- 3. compat.h supplies upstream's exact value when absent -------------
assert_file_matches "$COMPAT" "#ifndef[[:space:]]+$FLAG" \
	"compat.h must guard the BLK_STS_P2PDMA fallback on #ifndef $FLAG"
assert_file_matches "$COMPAT" \
	"#define[[:space:]]+BLK_STS_P2PDMA[[:space:]]+\(\(__force[[:space:]]+blk_status_t\)18\)" \
	"compat.h must define BLK_STS_P2PDMA to upstream's value 18"

dkms_pass "BLK_STS_P2PDMA compat gating: probe is present-aware and fallback uses value 18"
