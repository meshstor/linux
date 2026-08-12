#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
# P4c: rdma-leg advertise gate, driver- and substrate-aware.
#
# What the meshstor-nvme-rdma override (backport of 23528aa3320a) does --
# and correctly does NOT do -- to BLK_FEAT_PCI_P2PDMA on a loopback
# nvme-rdma leg:
#   multipath head present -> the feature is masked by the head split
#     (set on the hidden path disk in nvme_alloc_ns; NOT in
#     BLK_FEAT_INHERIT_MASK, so it never reaches the head gendisk the
#     campaign probes and consumes). PASS with driver+substrate recorded;
#     the leg-level matrix needs a nvme_core.multipath=N boot.
#   stock driver (<7.1)  -> leg must NOT advertise (op absent).
#   override + rxe/siw   -> leg must NOT advertise: ib_uses_virt_dma()
#     makes ib_dma_pci_p2p_dma_supported() false. Correct refusal.
#   override + hw HCA    -> leg MUST advertise, and a raid1 of
#     [advertising local leg, advertising rdma leg] MUST advertise
#     (member-AND both-advertise positive case).
# GPU-independent.
set -eu
DIR="$(dirname "$0")"; . "$DIR/lib.sh"
p2pdma_require_root; p2pdma_require_modules; p2pdma_require_tools
command -v nvme >/dev/null || { echo "SKIP: nvme-cli missing" >&2; exit 4; }
QF="$(gds_tool ms-queue-features)"
trap gds_teardown EXIT

p2pdma_pick_members raid1
[ "$P2PDMA_SUBSTRATE" = nvme ] || { echo "SKIP: needs real NVMe test partitions" >&2; exit 4; }
M0="$P2PDMA_M0"; M1="$P2PDMA_M1"

"$QF" "$M0" || { echo "SKIP: local member $M0 does not advertise P2P on this box" >&2; exit 4; }

# --- driver: which nvme-rdma will serve the connect? -----------------------
modprobe nvme_rdma 2>/dev/null || true
NR_FILE=$(modinfo -F filename nvme_rdma 2>/dev/null || true)
case "$NR_FILE" in
*builtin*) echo "SKIP: nvme_rdma is built-in (CONFIG_NVME_RDMA=y): not overridable" >&2; exit 4;;
"")        echo "SKIP: nvme_rdma unavailable" >&2; exit 4;;
esac
NR_DISK=$(modinfo -F srcversion nvme_rdma 2>/dev/null || true)
NR_LOADED=$(cat /sys/module/nvme_rdma/srcversion 2>/dev/null || true)
DRIVER=stock; DRIVER_NOTE=""
case "$NR_FILE" in
*/updates/*)
	# loadedness via initstate (srcversion can be absent on kernels
	# without CONFIG_MODULE_SRCVERSION_ALL); build identity via
	# loaded-vs-ondisk srcversion equality.
	if [ ! -e /sys/module/nvme_rdma/initstate ] || [ "$NR_LOADED" = "$NR_DISK" ]; then
		DRIVER=override
	else
		DRIVER_NOTE=" (override installed but not loaded)"
	fi;;
esac

gds_nvmet_export rdma "$M1"
REMOTE="${GDS_REMOTE_DEVS[0]}"

# --- substrate of the ibdev that owns the export address -------------------
SUBSTRATE=hw
case "${GDS_RDMA_IBDEV:-}" in rxe*|siw*) SUBSTRATE=virt;; esac

# --- head-split rung: on multipath=Y boots the fabrics node is the head ----
IS_HEAD=0
case "$(readlink "/sys/class/block/$(basename "$REMOTE")" 2>/dev/null)" in
*nvme-subsystem*) IS_HEAD=1;;
esac

rc=0; "$QF" "$REMOTE" >/dev/null || rc=$?

if [ "$IS_HEAD" = 1 ]; then
	case $rc in
	1)	MSG="multipath head masks leg advertise (BLK_FEAT_PCI_P2PDMA not in BLK_FEAT_INHERIT_MASK); driver=$DRIVER$DRIVER_NOTE substrate=$SUBSTRATE; boot nvme_core.multipath=N for the leg-level matrix"
		gds_verdict p4c rdma_gate PASS "$MSG"
		echo "PASS: $MSG"
		exit 0;;
	0)	MSG="head advertises P2P -- unexpected feature propagation (new kernel behavior?)"
		gds_verdict p4c rdma_gate FAIL "$MSG"
		echo "FAIL: $MSG" >&2
		exit 1;;
	*)	echo "SKIP: cannot probe queue features on $REMOTE (rc=$rc)" >&2; exit 4;;
	esac
fi

# --- non-head: the driver x substrate matrix --------------------------------
case "$DRIVER/$SUBSTRATE/$rc" in
stock/*/1)
	if [ -n "$DRIVER_NOTE" ]; then
		MSG="stock$DRIVER_NOTE: rdma leg does not advertise; reload the override (modprobe -r nvme_rdma && modprobe nvme_rdma)"
	else
		MSG="stock: rdma leg does not advertise; on hw substrates install the override (23528aa first in v7.1-rc2)"
	fi
	gds_verdict p4c rdma_gate PASS "$MSG"
	echo "PASS: $MSG"
	exit 0;;
stock/hw/0)
	MSG="stock driver advertises -- kernel >= 7.1-rc2, override unnecessary"
	gds_verdict p4c rdma_gate INFO "$MSG"
	echo "PASS: $MSG"
	exit 0;;
*/virt/0)
	MSG="virt-DMA leg advertises -- ib_uses_virt_dma refusal bypassed (kernel bug?)"
	gds_verdict p4c rdma_gate FAIL "$MSG"
	echo "FAIL: $MSG" >&2
	exit 1;;
override/virt/1)
	MSG="override+virt-DMA: refusal is correct (ib_uses_virt_dma)"
	gds_verdict p4c rdma_gate PASS "$MSG"
	echo "PASS: $MSG"
	exit 0;;
override/hw/1)
	MSG="override active but hw leg does not advertise -- check dma_pci_p2pdma_supported on the HCA (IOMMU/ACS config)"
	gds_verdict p4c rdma_gate FAIL "$MSG"
	echo "FAIL: $MSG" >&2
	exit 1;;
override/hw/0)
	;; # the positive case -- fall through to the member-AND build below
*)
	echo "SKIP: cannot probe queue features on $REMOTE (rc=$rc)" >&2; exit 4;;
esac

# --- override x hw x advertises: member-AND both-advertise positive case ----
gds_csi_mdadm_create /dev/ms0 1 "$M0" "$REMOTE" >/dev/null 2>&1 \
	|| { echo "SKIP: array create failed" >&2; exit 4; }
P2PDMA_ARRAY=/dev/ms0

rc=0; "$QF" /dev/ms0 >/dev/null || rc=$?
case $rc in
0)	MSG="override+hw: leg=adv array=adv (member-AND positive)"
	gds_verdict p4c rdma_gate PASS "$MSG"
	echo "PASS: $MSG"
	exit 0;;
1)	MSG="override+hw: leg advertises but array does not -- member-AND broken in the both-advertise direction"
	gds_verdict p4c rdma_gate FAIL "$MSG"
	echo "FAIL: $MSG" >&2
	exit 1;;
*)	echo "SKIP: cannot probe queue features on /dev/ms0 (rc=$rc)" >&2; exit 4;;
esac
