#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
#
# TDD Fix A — patch 0003 must gate the kernel-UAPI struct field
# `mdp_superblock_1.logical_block_size` on a struct-scoped HAVE_* feature
# flag, NOT on `#if LINUX_VERSION_CODE >= KERNEL_VERSION(6,18,0)`.
#
# Why: a vendor kernel (Rocky/RHEL 10.x, Ubuntu HWE) can backport the field
# while keeping a <6.18 version string. The version gate then compiles out
# the superblock read+write of a field that physically exists — de-pinning
# the array logical block size and (on the write path) persisting a zero
# LBS into the on-disk superblock. See .full-review findings F1 / A1 / A2 / S1.
#
# This test pins both halves of the fix:
#   1. the patch gates on #ifdef HAVE_MDP_SB1_LOGICAL_BLOCK_SIZE
#   2. dkms/Makefile.in's feature_flags target detects the field correctly,
#      struct-scoped (a comment or an unrelated struct must not trigger it).

set -u
# shellcheck source=tools/testing/selftests/dkms/lib.sh
. "$(dirname "$0")/lib.sh"

PATCH="$REPO_ROOT/dkms/patches/0003-pre-6.18-no-mdp-superblock-1-logical-block-size.patch"
FLAG="HAVE_MDP_SB1_LOGICAL_BLOCK_SIZE"

[ -f "$PATCH" ] || dkms_fail "patch 0003 not found at $PATCH"

# --- 1. the patch uses the feature flag, not a version check -------------
assert_file_not_matches "$PATCH" 'LINUX_VERSION_CODE' \
	"patch 0003 still uses LINUX_VERSION_CODE — must gate on a HAVE_* flag"
assert_file_matches "$PATCH" "#ifn?def[[:space:]]+$FLAG" \
	"patch 0003 must gate the field accesses on #ifdef $FLAG"

# --- 2. feature_flags emits the flag when the field IS present -----------
kdir_present="$(dkms_make_kdir)"
cat > "$kdir_present/include/uapi/linux/raid/md_p.h" <<'EOF'
struct mdp_superblock_1 {
	__le32	magic;
	__le32	major_version;
	__le32	feature_map;
	__le32	logical_block_size;	/* same as q->limits.logical_block_size */
	__u8	pad3[64-32];
};
EOF
ff="$(dkms_run_feature_flags "$kdir_present")" \
	|| dkms_fail "feature_flags run failed (field-present fixture)"
assert_file_matches "$ff" "#define[[:space:]]+${FLAG}[[:space:]]+1" \
	"feature_flags must define $FLAG when mdp_superblock_1 has the field"

# --- 3. NOT emitted when the field is absent -----------------------------
kdir_absent="$(dkms_make_kdir)"
cat > "$kdir_absent/include/uapi/linux/raid/md_p.h" <<'EOF'
struct mdp_superblock_1 {
	__le32	magic;
	__le32	major_version;
	__le32	feature_map;
	__le32	padding;
	__u8	pad3[64-32];
};
EOF
ff="$(dkms_run_feature_flags "$kdir_absent")" \
	|| dkms_fail "feature_flags run failed (field-absent fixture)"
assert_file_not_matches "$ff" "$FLAG" \
	"feature_flags must NOT define $FLAG when the field is absent"

# --- 4. struct-scoped: a comment mentioning the token, or the token as a
#        field of a DIFFERENT struct, must NOT trigger the flag -----------
kdir_decoy="$(dkms_make_kdir)"
cat > "$kdir_decoy/include/uapi/linux/raid/md_p.h" <<'EOF'
/* This kernel has no logical_block_size in the superblock. */
struct mdp_superblock_1 {
	__le32	magic;
	/* note: logical_block_size lives in queue_limits, not here */
	__u8	pad3[64-32];
};
struct some_other_struct {
	unsigned int logical_block_size;
};
EOF
ff="$(dkms_run_feature_flags "$kdir_decoy")" \
	|| dkms_fail "feature_flags run failed (decoy fixture)"
assert_file_not_matches "$ff" "$FLAG" \
	"feature_flags detection must be struct-scoped: a comment or an unrelated struct must not trigger $FLAG"

dkms_pass "patch 0003 gates on $FLAG; detection is struct-scoped and correct"
