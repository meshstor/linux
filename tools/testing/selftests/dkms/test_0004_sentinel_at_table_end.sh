#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
#
# TDD Fix B — patch 0004's `{ }` sysctl sentinel must land as the LAST
# element of raid_table[], inside the #ifndef HAVE_SYSCTL_REGISTER_TABLE_
# NO_SENTINEL guard, immediately before the table's closing `};`.
#
# Why: 0004's hunk header was fabricated (`@@ -1,5 +1,13 @@`) and its
# context (`.proc_handler = proc_dointvec,` / `},`) is NOT unique —
# raid_table[] has three identical entries. The hunk previously landed at
# the right spot only by luck of fuzz matching. If it ever lands mid-table,
# the NULL-procname sentinel truncates the sysctl registration on pre-6.4
# kernels. This test pins the semantic outcome, not just "the patch
# applied". See .full-review finding F2.

set -u
# shellcheck source=tools/testing/selftests/dkms/lib.sh
. "$(dirname "$0")/lib.sh"

ktree="$(dkms_resolve_kernel_tree)" \
	|| dkms_skip "no drivers/md tree (set KERNEL_TREE= or run bin/rebuild-meshstor-main first)"
tree="$(dkms_flat_manifest_tree "$ktree")"

if ! out="$(dkms_apply_all_patches "$tree")"; then
	echo "FAIL: a patch was rejected under --fuzz=0 (cannot check 0004 placement)" >&2
	echo "$out" >&2
	exit 1
fi

# Extract the raid_table[] definition block, from its opening to its
# closing `};`.
block="$(awk '
	/static const struct ctl_table raid_table\[\][[:space:]]*=[[:space:]]*\{/ { f = 1 }
	f { print }
	f && /^\};/ { exit }
' "$tree/md.c")"

[ -n "$block" ] || dkms_fail "could not locate raid_table[] in patched md.c"

# Exactly one bare `{ }` sentinel, and it must be inside raid_table[].
n_sentinel="$(printf '%s\n' "$block" | grep -cE '^[[:space:]]*\{ \}[[:space:]]*$')"
assert_eq "1" "$n_sentinel" \
	"raid_table[] must contain exactly one { } sentinel (found $n_sentinel)"

# The last meaningful (non-blank, non-comment) lines of the block must be
# the guarded sentinel immediately before the closing brace.
tail4="$(printf '%s\n' "$block" \
	| grep -vE '^[[:space:]]*(/\*|\*|//)' \
	| grep -vE '^[[:space:]]*$' \
	| tail -4)"
expected="$(printf '#ifndef HAVE_SYSCTL_REGISTER_TABLE_NO_SENTINEL\n\t{ }\n#endif\n};')"
assert_eq "$expected" "$tail4" \
	"0004 sentinel must be the last element of raid_table[], inside the #ifndef guard"

dkms_pass "0004 sentinel lands as the last element of raid_table[], correctly guarded"
