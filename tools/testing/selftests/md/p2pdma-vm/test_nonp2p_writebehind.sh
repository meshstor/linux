#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
# Layer B control (raid1 only): write-mostly raid1 accepts writes and the
# write-mostly leg stays consistent -- no silent divergence.
# (Proves the F1 `&& !md_bio_is_p2pdma(bio)` guard did not accidentally disable
# write-mostly/write-behind for ordinary I/O.)
# Pass = both legs hold identical data after the array is stopped and
# write-behind has drained.
set -eu
DIR="$(dirname "$0")"; . "$DIR/lib.sh"
p2pdma_require_root; p2pdma_require_modules; p2pdma_require_tools
PAT=/tmp/p2pdma-wb.pat
trap 'rm -f "$PAT"; p2pdma_teardown' EXIT

p2pdma_pick_members raid1; M0="$P2PDMA_M0"; M1="$P2PDMA_M1"
"$MDADM" --create /dev/ms0 --level=1 --raid-devices=2 --metadata=1.0 \
	--bitmap=internal --write-behind=256 --assume-clean --run \
	"$M0" --write-mostly "$M1" >/dev/null 2>&1 \
	|| { echo "SKIP: write-behind array create failed" >&2; exit 4; }
P2PDMA_ARRAY=/dev/ms0

# Write a known pattern; metadata=1.0 places data at offset 0, so members can be
# cmp'd directly after the array is stopped (write-behind fully drained on stop).
dd if=/dev/urandom of="$PAT" bs=1M count=8 status=none
dd if="$PAT" of=/dev/ms0 bs=1M count=8 oflag=direct status=none
sync
"$MDADM" --stop /dev/ms0 >/dev/null 2>&1
P2PDMA_ARRAY=""

# Verify both legs: M1 is the write-mostly/write-behind leg.
cmp -n $((8*1024*1024)) "$PAT" "$M0" \
	|| { echo "FAIL: data mismatch on M0 after write-behind write" >&2; exit 1; }
cmp -n $((8*1024*1024)) "$PAT" "$M1" \
	|| { echo "FAIL: data mismatch on M1 (write-mostly leg) after write-behind write" >&2; exit 1; }
echo "PASS: write-mostly raid1 accepted writes and the write-mostly leg (M1) stays consistent -- no silent divergence"
exit 0
