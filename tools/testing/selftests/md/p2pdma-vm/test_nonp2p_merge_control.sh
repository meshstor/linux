#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
# Layer B control: md still CLEARS REQ_NOMERGE for non-P2P I/O, so member-level
# request merging still happens (the F1 detector did not over-fire on normal I/O).
# Pass = member shows >0 merged writes (field 6 of /sys/block/.../stat) after a
# sequential, mergeable workload.  On loop substrate merges are not observable;
# the test SKIPs rather than asserting a vacuous counter.
set -eu
DIR="$(dirname "$0")"; . "$DIR/lib.sh"
p2pdma_require_root; p2pdma_require_modules; p2pdma_require_tools
trap p2pdma_teardown EXIT

p2pdma_pick_members raid1; M0="$P2PDMA_M0"; M1="$P2PDMA_M1"
"$MDADM" --create /dev/ms0 --level=1 --raid-devices=2 --assume-clean \
	--run "$M0" "$M1" >/dev/null 2>&1 || { echo "SKIP: array create failed" >&2; exit 4; }
P2PDMA_ARRAY=/dev/ms0
# -d (nodeps): with the array active, a dependent-tree listing can emit the
# md holder (ms0) first and `head -1` then reads the ARRAY's stat -- md never
# merges, so the assertion always failed against the wrong device (hit live
# on the L40S box; the fix reads the member partition itself).
KN="$(lsblk -dno KNAME "$M0")"

before="$(awk '{print $6}' /sys/class/block/"$KN"/stat)"   # field 6 = write merges (wrqm)
fio --name=seq --filename=/dev/ms0 --rw=write --bs=8k --iodepth=16 \
    --ioengine=libaio --direct=1 --size=64M --numjobs=1 >/dev/null 2>&1
after="$(awk '{print $6}' /sys/class/block/"$KN"/stat)"

merged=$(( after - before ))
echo "substrate=$P2PDMA_SUBSTRATE member=$KN writes_merged=$merged"

if [ "$P2PDMA_SUBSTRATE" = loop ]; then
	echo "SKIP: member merge counters not reliably observable on loop" >&2
	exit 4
fi

[ "$merged" -gt 0 ] \
	|| { echo "FAIL: no member merges -- REQ_NOMERGE may be over-preserved for non-P2P I/O" >&2; exit 1; }
echo "PASS: non-P2P I/O still merges at the member $KN ($merged)"; exit 0
