#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
#
# Real compile of the vendored+patched nvme-rdma against an installed
# kernel's headers, when one matching a vendored family is present
# (this dev box runs Ubuntu 24.04 HWE 6.17 -> u2404-hwe). SKIPs
# otherwise. Asserts: correct variant selected, nvme-rdma.ko produced,
# no modpost "undefined!" warnings (i.e. every imported symbol resolved
# against the target kernel's Module.symvers).
set -u
# shellcheck source=tools/testing/selftests/dkms/lib.sh
. "$(dirname "$0")/lib.sh"

[ -d "$REPO_ROOT/dkms-nvme/vendor/u2404-hwe" ] \
	|| dkms_skip "vendor sources not populated (run bin/vendor-nvme-sources)"

pick_variant() { # $1 = kernel release -> echoes variant key, or nothing
	case "$1" in
		*.el10*) echo rhel10 ;;
		6.17.*)  echo u2404-hwe ;;
		7.0.*)   echo u2604 ;;
	esac
}

KVER= VARIANT=
for m in /lib/modules/*; do
	k="$(basename "$m")"
	[ -f "$m/build/Makefile" ] || continue
	v="$(pick_variant "$k")"
	[ -n "$v" ] && { KVER="$k"; VARIANT="$v"; break; }
done
[ -n "$KVER" ] || dkms_skip "no installed kernel headers match a vendored family"

VER="0.0.smoke"
"$REPO_ROOT/bin/build-nvme-tarball" "$VER" >/dev/null \
	|| dkms_fail "build-nvme-tarball failed"

d="$(dkms_mktemp_dir)"
tar xzf "$REPO_ROOT/build/meshstor-nvme-rdma-$VER.dkms.tar.gz" -C "$d"
src="$d/meshstor-nvme-rdma-$VER"
log="$d/build.log"

if ! make -C "$src" KVER="$KVER" KDIR="/lib/modules/$KVER/build" >"$log" 2>&1; then
	tail -30 "$log" >&2
	dkms_fail "module build failed (variant $VARIANT, kernel $KVER)"
fi
grep -q "building variant $VARIANT" "$log" \
	|| dkms_fail "wrong variant selected (wanted $VARIANT)"
[ -f "$src/nvme-rdma.ko" ] || dkms_fail "nvme-rdma.ko not produced"
if grep -i 'undefined!' "$log"; then
	dkms_fail "modpost reported undefined symbols"
fi
modinfo "$src/nvme-rdma.ko" 2>/dev/null | grep -qi 'rdma' \
	|| dkms_fail "modinfo of built nvme-rdma.ko looks wrong"

rm -rf "$REPO_ROOT/build/meshstor-nvme-rdma-$VER" \
       "$REPO_ROOT/build/meshstor-nvme-rdma-$VER.dkms.tar.gz"
dkms_pass "vendored $VARIANT compiles against $KVER; modpost clean"
