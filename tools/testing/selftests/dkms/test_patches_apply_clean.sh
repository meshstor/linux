#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
#
# Every dkms/patches/*.patch must apply to the composed drivers/md/ manifest
# sources, in glob order, under `patch -p1 --fuzz=0`, producing NO fuzz and NO
# rejected hunk. Benign line OFFSETS are allowed: the composed tree's line
# numbers shift with the feature set/order, so requiring zero offset would
# force the patches to be re-regenerated on every lineage change. --fuzz=0
# still forbids fuzzy/mis-targeted hunks (a hunk needing fuzz is rejected),
# which is the real hazard the original guard targeted (.full-review F2/F3/F4).
#
# Sources come from dkms_resolve_kernel_tree (KERNEL_TREE override, else an
# in-repo or composed drivers/md). The meshstor-harness branch carries no
# drivers/md, so this SKIPs there unless a composed tree is available.

set -u
# shellcheck source=tools/testing/selftests/dkms/lib.sh
. "$(dirname "$0")/lib.sh"

ktree="$(dkms_resolve_kernel_tree)" \
	|| dkms_skip "no drivers/md tree (set KERNEL_TREE= or run bin/rebuild-meshstor-main first)"
tree="$(dkms_flat_manifest_tree "$ktree")"

if ! out="$(dkms_apply_all_patches "$tree")"; then
	echo "FAIL: a patch was rejected under --fuzz=0 (fuzzy/mis-targeted hunk)" >&2
	echo "$out" >&2
	exit 1
fi

assert_not_contains "$out" "fuzz" \
	"patches must apply with no fuzz under --fuzz=0"$'\n'"$out"
assert_not_contains "$out" "FAILED" \
	"patches must apply with no rejected hunks"$'\n'"$out"

n_patches="$(find "$REPO_ROOT"/dkms/patches -name '*.patch' | wc -l | tr -d ' ')"
dkms_pass "all $n_patches patches apply in glob order under --fuzz=0, no fuzz, no reject (offsets ok)"
