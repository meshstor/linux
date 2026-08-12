#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
# P4a: the member-AND gate. nvme-tcp never advertises BLK_FEAT_PCI_P2PDMA (no
# supports_pci_p2pdma ctrl op), so a raid1 of [P2P-capable local leg, loopback
# nvme-tcp leg] must NOT advertise. GPU-independent.
# PASS = local member advertises, tcp namespace does not, array does not.
# SKIP = no advertising local member on this box (assertion would be vacuous).
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

gds_nvmet_export tcp "$M1"
REMOTE="${GDS_REMOTE_DEVS[0]}"
if "$QF" "$REMOTE"; then
	echo "FAIL: loopback nvme-tcp namespace $REMOTE advertises P2P (Finding E violated?)" >&2
	exit 1
fi

gds_csi_mdadm_create /dev/ms0 1 "$M0" "$REMOTE" >/dev/null 2>&1 \
	|| { echo "SKIP: array create failed" >&2; exit 4; }
P2PDMA_ARRAY=/dev/ms0

if "$QF" /dev/ms0; then
	echo "FAIL: array advertises P2P with a tcp (non-P2P) leg -- member-AND gate broken" >&2
	exit 1
fi
gds_verdict p4a member_and PASS "local=adv tcp-ns=not array=not"
echo "PASS: tcp leg correctly suppresses the array's P2P advertisement"
exit 0
