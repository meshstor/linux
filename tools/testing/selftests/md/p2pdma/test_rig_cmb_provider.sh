#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
# Rig probe: prove QEMU's emulated NVMe CMB registers as a p2pdma
# provider in the guest. Everything else in this suite depends on this.
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
if [ -z "${P2P_IN_VM:-}" ]; then
	exec "$DIR/run_vm.sh" symmetric \
		env P2P_IN_VM=1 MS_MOD_DIR="${MS_MOD_DIR:-}" "$DIR/$(basename "$0")"
fi
. "$DIR/lib.sh"
p2p_require_root
BDF="$(p2p_bdf_by_serial cmb0)" || p2p_fail "cmb0 nvme not found in guest"
# nvme core registers the CMB via pci_p2pdma_add_resource; the provider
# then exposes p2pmem stats in sysfs.
AVAIL="/sys/bus/pci/devices/$BDF/p2pmem/available"
[ -f "$AVAIL" ] || p2p_fail "no p2pmem provider at $BDF (CMB not registered)"
[ "$(cat "$AVAIL")" -gt 0 ] || p2p_fail "p2pmem pool empty at $BDF"
p2p_pass "CMB p2pdma provider registered: $BDF, available=$(cat "$AVAIL")"
