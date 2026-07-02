#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
#
# The meshstor-nvme-rdma wrapper Makefile must select the vendored source
# variant from the target kernel release string — rhel10 for *.el10*,
# u2404-hwe for 6.17.*, u2604 for 7.0.* — and hard-error with the
# supported-family list on anything else. It must also refuse a KDIR
# whose utsrelease.h disagrees with KVER (ABI-pinned override module:
# building variant X against kernel Y is the exact failure this package
# exists to prevent).
set -u
# shellcheck source=tools/testing/selftests/dkms/lib.sh
. "$(dirname "$0")/lib.sh"

MAKEFILE_IN="$REPO_ROOT/dkms-nvme/Makefile.in"
[ -f "$MAKEFILE_IN" ] || dkms_fail "dkms-nvme/Makefile.in not found"
command -v make >/dev/null 2>&1 || dkms_skip "make not installed"

d="$(dkms_mktemp_dir)"
sed 's/@VERSION@/0.0.test/g' "$MAKEFILE_IN" > "$d/Makefile"

want() { # KVER EXPECTED_VARIANT
	local got
	got="$(make -s -C "$d" print-variant KVER="$1")" \
		|| dkms_fail "print-variant failed for KVER=$1"
	assert_eq "$2" "$got" "variant selected for KVER=$1"
}
want 6.12.0-211.26.1.el10_2.x86_64 rhel10
want 6.17.0-35-generic             u2404-hwe
want 7.0.0-27-generic              u2604

# Unsupported family -> hard error naming the supported list.
out="$(make -s -C "$d" variant-check KVER=6.8.0-136-generic KDIR=/nonexistent 2>&1)" \
	&& dkms_fail "variant-check must fail for unsupported 6.8 kernel"
assert_contains "$out" "unsupported kernel" "unsupported-kernel error message"

# KVER/KDIR utsrelease mismatch -> refused.
mkdir -p "$d/kdir/include/generated"
echo '#define UTS_RELEASE "6.17.0-99-generic"' > "$d/kdir/include/generated/utsrelease.h"
out="$(make -s -C "$d" variant-check KVER=6.17.0-35-generic KDIR="$d/kdir" 2>&1)" \
	&& dkms_fail "variant-check must fail when KDIR utsrelease != KVER"
assert_contains "$out" "6.17.0-99-generic" "utsrelease mismatch message"

dkms_pass "variant selection and safety guards behave"
