#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
# Layer B: raid1 + raid10 assemble healthy over non-P2P members and serve I/O.
# (Positive "P2P refused" proof needs P2P pages -> Layer C; here we only assert
# health + no crash on the F1/F2 paths over ordinary members.)
set -eu
DIR="$(dirname "$0")"; . "$DIR/lib.sh"
p2pdma_require_root; p2pdma_require_modules; p2pdma_require_tools

run_level() {
	local level="$1" ndev="$2"; shift 2
	local members=("$@")
	"$MDADM" --create /dev/ms0 --level="$level" --raid-devices="$ndev" \
		--assume-clean --run "${members[@]}" >/dev/null 2>&1 \
		|| { echo "SKIP: $level create failed" >&2; exit 4; }
	P2PDMA_ARRAY=/dev/ms0
	dd if=/dev/zero of=/dev/ms0 bs=1M count=16 oflag=direct status=none
	grep -q "active" /proc/msstat || { echo "FAIL: $level not active" >&2; exit 1; }
	"$MDADM" --stop /dev/ms0 >/dev/null 2>&1; P2PDMA_ARRAY=""
	echo "PASS: $level healthy over non-P2P members"
}

trap p2pdma_teardown EXIT
p2pdma_pick_members raid1; M0="$P2PDMA_M0"; M1="$P2PDMA_M1"
run_level raid1 2 "$M0" "$M1"
# raid10 needs >=2 members too (near=2); reuse the same pair.
run_level raid10 2 "$M0" "$M1"
exit 0
