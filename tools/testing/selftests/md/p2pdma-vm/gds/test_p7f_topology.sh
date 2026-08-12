#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
# P7f: OPPORTUNISTIC TRUE TOPOLOGY. If the box has an NVMe test-partition
# pair spanning PCI root complexes, build the asymmetric CSI raid1 and
# attempt a strict native write with ZERO injector involvement. Outcomes:
#   (a) EINVAL WITH the breadcrumb and witnessed P2P bios  => PASS
#       (the natural arm firing on a real unreachable topology)
#   (b) EINVAL, witness-zero, no breadcrumb                => SKIP
#       "cuFile refused the topology in userspace" (vacuity guard)
#   (c) witnessed native SUCCESS                           => SKIP/INFO
#       "platform whitelists cross-RC P2P" — NEVER a FAIL (whitelisted
#       host bridges legitimately permit cross-RC P2P)
set -eu
DIR="$(dirname "$0")"; . "$DIR/lib.sh"
p2pdma_require_root; p2pdma_require_modules; p2pdma_require_tools
gds_require_gdsio
QF="$(gds_tool ms-queue-features)"
WITNESS="$(gds_tool gds-p2p-witness)"
trap gds_teardown EXIT

# PCI root segment of a partition's parent disk (e.g. "pci0000:16")
gds_pci_root() {
	local pk path
	pk=$(lsblk -dno PKNAME "$1" | head -1)
	[ -n "$pk" ] || pk=$(lsblk -dno KNAME "$1" | head -1)
	path=$(readlink -f "/sys/block/$pk/device" 2>/dev/null) || return 1
	echo "$path" | grep -oE 'pci[0-9a-f]{4}:[0-9a-f]{2}' | head -1
}

PARTS=()
for d in /dev/disk/by-partlabel/*-meshstor-test-*; do
	[ -e "$d" ] && PARTS+=("$d")
done
[ "${#PARTS[@]}" -ge 2 ] || { echo "SKIP: no cross-RC NVMe pair (fewer than 2 test partitions)" >&2; exit 4; }

M0=""; M1=""
for a in "${PARTS[@]}"; do
	for b in "${PARTS[@]}"; do
		[ "$a" = "$b" ] && continue
		RA=$(gds_pci_root "$a" || echo x); RB=$(gds_pci_root "$b" || echo y)
		if [ -n "$RA" ] && [ -n "$RB" ] && [ "$RA" != "$RB" ]; then
			M0=$a; M1=$b; echo "cross-RC pair: $a ($RA) x $b ($RB)"; break 2
		fi
	done
done
[ -n "$M0" ] || { echo "SKIP: no cross-RC NVMe pair among test partitions (all share one root complex)" >&2; exit 4; }

rc=0; "$QF" "$M0" >/dev/null || rc=$?
[ "$rc" != 4 ] || { echo "SKIP: cannot probe member advertise (bpftrace)" >&2; exit 4; }
[ "$rc" = 0 ] || { echo "SKIP: members do not advertise P2P on this box" >&2; exit 4; }
gds_csi_mdadm_create /dev/ms0 1 "$M0" "$M1" >/dev/null 2>&1 \
	|| { echo "SKIP: array create failed" >&2; exit 4; }
P2PDMA_ARRAY=/dev/ms0
rc=0; "$QF" /dev/ms0 >/dev/null || rc=$?
[ "$rc" != 4 ] || { echo "SKIP: cannot probe queue features on /dev/ms0 (rc=4)" >&2; exit 4; }
[ "$rc" = 0 ] || { echo "SKIP: /dev/ms0 does not advertise P2P (qf rc=$rc)" >&2; exit 4; }

gds_mkfs_mount /dev/ms0 "$GDS_MNT" || { echo "SKIP: mkfs/mount failed" >&2; exit 4; }
JSON=$(gds_cufile_json strict "$GDS_RESULTS/p7f")
gds_dmesg_mark

rc=0; "$WITNESS" --expect-ms any --expect-rc any -o "$GDS_RESULTS/p7f-witness.txt" -- \
	bash -c "$(declare -f gds_gdsio_write); GDSIO='$GDSIO' GDS_RESULTS='$GDS_RESULTS' gds_gdsio_write '$GDS_MNT' 0 '$JSON'" || rc=$?
[ "$rc" != 4 ] || { echo "SKIP: witness could not attach" >&2; exit 4; }
WREPORT=$(head -1 "$GDS_RESULTS/p7f-witness.txt" 2>/dev/null || echo "")
P2P=$(echo "$WREPORT" | sed -n 's/^p2p_bios=\([0-9]*\).*/\1/p'); P2P=${P2P:-0}
WRC=$(echo "$WREPORT" | sed -n 's/.*cmd_rc=\([0-9]*\).*/\1/p'); WRC=${WRC:-1}
BREAD=0; gds_dmesg_delta | grep -q 'no P2P path' && BREAD=1

umount "$GDS_MNT" 2>/dev/null || true
if timeout 60 "$MDADM" --stop /dev/ms0 >/dev/null 2>&1; then
	P2PDMA_ARRAY=""
else
	# leave P2PDMA_ARRAY set: the EXIT-trap teardown retries the stop and
	# the failure surfaces there instead of being masked here
	echo "WARN: mdadm --stop /dev/ms0 failed/timed out — deferred to the EXIT trap" >&2
fi

if [ "$WRC" != 0 ] && [ "$P2P" -gt 0 ] && [ "$BREAD" = 1 ]; then
	gds_verdict p7 p7f PASS "natural arm: EINVAL + breadcrumb + witnessed P2P bios ($WREPORT)"
	echo "PASS: natural stage-1 arm fired on a real cross-RC topology (no injector)"
	exit 0
elif [ "$WRC" != 0 ] && [ "$P2P" -eq 0 ] && [ "$BREAD" = 0 ]; then
	gds_verdict p7 p7f SKIP "cuFile refused the topology in userspace (witness-zero, no kernel I/O)"
	echo "SKIP: cuFile refused the topology in userspace (vacuity guard — no kernel I/O happened)" >&2
	exit 4
elif [ "$WRC" = 0 ] && [ "$P2P" -gt 0 ]; then
	gds_verdict p7 p7f INFO "platform whitelists cross-RC P2P ($WREPORT)"
	echo "SKIP: platform whitelists cross-RC P2P — witnessed native success, never a FAIL" >&2
	exit 4
elif [ "$WRC" = 0 ] && [ "$P2P" -eq 0 ]; then
	gds_verdict p7 p7f SKIP "no native attempt (strict run succeeded with witness-zero — investigate rig)"
	echo "SKIP: no native attempt (witness zero on a strict success)" >&2
	exit 4
else
	gds_verdict p7 p7f FAIL "EINVAL with witnessed P2P but NO breadcrumb: $WREPORT"
	echo "FAIL: native attempt failed without the stage-1 breadcrumb — investigate before trusting the arm" >&2
	exit 1
fi
