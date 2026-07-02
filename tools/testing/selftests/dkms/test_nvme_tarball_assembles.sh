#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
#
# bin/build-nvme-tarball must assemble the meshstor-nvme-rdma DKMS
# tarball: all three vendored variants present with PROVENANCE, the
# per-variant p2pdma backport applied (the script enforces --fuzz=0 and
# fails loudly otherwise), and the templates rendered with the version.
set -u
# shellcheck source=tools/testing/selftests/dkms/lib.sh
. "$(dirname "$0")/lib.sh"

[ -x "$REPO_ROOT/bin/build-nvme-tarball" ] || dkms_fail "bin/build-nvme-tarball missing"
[ -d "$REPO_ROOT/dkms-nvme/vendor/u2404-hwe" ] \
	|| dkms_skip "vendor sources not populated (run bin/vendor-nvme-sources)"

VER="0.0.selftest"
out="$("$REPO_ROOT/bin/build-nvme-tarball" "$VER" 2>&1)" \
	|| dkms_fail "build-nvme-tarball failed: $out"
TB="$REPO_ROOT/build/meshstor-nvme-rdma-$VER.dkms.tar.gz"
[ -f "$TB" ] || dkms_fail "tarball not produced at $TB"

d="$(dkms_mktemp_dir)"
tar xzf "$TB" -C "$d"
root="$d/meshstor-nvme-rdma-$VER"
for v in u2404-hwe u2604 rhel10; do
	for f in rdma.c nvme.h fabrics.h PROVENANCE; do
		[ -f "$root/$v/$f" ] || dkms_fail "missing $v/$f in tarball"
	done
	grep -q 'supports_pci_p2pdma' "$root/$v/rdma.c" \
		|| dkms_fail "$v/rdma.c lacks the p2pdma backport after assembly"
done
grep -q "PACKAGE_VERSION=\"$VER\"" "$root/dkms.conf" \
	|| dkms_fail "dkms.conf PACKAGE_VERSION not rendered"
grep -q 'BUILD_EXCLUSIVE_KERNEL=' "$root/dkms.conf" \
	|| dkms_fail "dkms.conf lacks BUILD_EXCLUSIVE_KERNEL"
grep -q 'NO_WEAK_MODULES="yes"' "$root/dkms.conf" \
	|| dkms_fail "dkms.conf lacks NO_WEAK_MODULES"
for f in Makefile README.md COPYING; do
	[ -f "$root/$f" ] || dkms_fail "missing $f in tarball root"
done

rm -rf "$REPO_ROOT/build/meshstor-nvme-rdma-$VER" "$TB"
dkms_pass "nvme tarball assembles; backport applied in all variants"
