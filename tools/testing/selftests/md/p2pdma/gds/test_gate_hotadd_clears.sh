#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
# P4b: raid1_p2pdma_clear_on_add(). An array advertising P2P (all-NVMe members)
# must DROP the advertisement when a non-P2P member (loop) is hot-added --
# before the new member becomes write-eligible. raid1 and raid10. GPU-independent.
# Arrays are created --size=131072 (128M) so a 256M loop is addable.
set -eu
DIR="$(dirname "$0")"; . "$DIR/lib.sh"
p2pdma_require_root; p2pdma_require_modules; p2pdma_require_tools
QF="$(gds_tool ms-queue-features)"
trap gds_teardown EXIT

p2pdma_pick_members raid1
[ "$P2PDMA_SUBSTRATE" = nvme ] || { echo "SKIP: needs real NVMe test partitions" >&2; exit 4; }
M0="$P2PDMA_M0"; M1="$P2PDMA_M1"
"$QF" "$M0" || { echo "SKIP: members do not advertise P2P on this box" >&2; exit 4; }

img=$(mktemp /tmp/gds-hotadd-XXXX.img); truncate -s 256M "$img"
LOOP=$(losetup --find --show "$img"); P2PDMA_LOOPS+=("$LOOP"); rm -f "$img"

run_level() {
	local level=$1
	gds_csi_mdadm_create /dev/ms0 "$level" "$M0" "$M1" -- --size=131072 \
		>/dev/null 2>&1 || { echo "SKIP: $level create failed" >&2; exit 4; }
	P2PDMA_ARRAY=/dev/ms0
	"$QF" /dev/ms0 || { echo "FAIL: $level all-NVMe array does not advertise" >&2; exit 1; }
	"$MDADM" --manage /dev/ms0 --fail "$M1" --remove "$M1" >/dev/null 2>&1
	"$QF" /dev/ms0 || { echo "FAIL: $level advertisement lost on REMOVAL (should persist)" >&2; exit 1; }
	"$MDADM" --manage /dev/ms0 --add "$LOOP" >/dev/null 2>&1 \
		|| { echo "SKIP: $level hot-add failed" >&2; exit 4; }
	if "$QF" /dev/ms0; then
		echo "FAIL: $level still advertises after adding non-P2P member -- clear_on_add broken" >&2
		exit 1
	fi
	gds_verdict p4b "hotadd_$level" PASS "advertise cleared on non-P2P add"
	"$MDADM" --stop /dev/ms0 >/dev/null 2>&1; P2PDMA_ARRAY=""
	# the loop now carries stale metadata; wipe for the next level
	"$MDADM" --zero-superblock "$LOOP" >/dev/null 2>&1 || true
	"$MDADM" --zero-superblock "$M0" "$M1" >/dev/null 2>&1 || true
}

run_level 1
run_level 10
echo "PASS: hot-add of a non-P2P member clears the advertisement (raid1 + raid10)"
exit 0
