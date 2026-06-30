# SPDX-License-Identifier: GPL-2.0
# Shared helpers for the p2pdma Layer-B (non-P2P control) selftests.
# Targets the meshstor-ms out-of-tree build (ms_*; /dev/msN, major ~252).
# Sourced by each test_*.sh; never run directly. Exit: 0 pass, 1 fail, 4 skip.
set -u

MDADM="${MDADM:-/home/mykola/mdadm/mdadm}"
P2PDMA_LOOPS=()
P2PDMA_ARRAY=""
P2PDMA_SUBSTRATE=""
P2PDMA_M0=""
P2PDMA_M1=""

p2pdma_require_root() { [ "$(id -u)" -eq 0 ] || { echo "SKIP: must run as root" >&2; exit 4; }; }

p2pdma_require_modules() {
	for m in ms_mod raid1_ms raid10_ms; do
		lsmod | grep -q "^$m " || { echo "SKIP: $m not loaded" >&2; exit 4; }
	done
	[ -x "$MDADM" ] || { echo "SKIP: meshstor mdadm not at $MDADM" >&2; exit 4; }
}

p2pdma_require_tools() {
	for t in losetup mdadm fio lsblk dd cmp; do
		command -v "$t" >/dev/null 2>&1 || { echo "SKIP: missing tool: $t" >&2; exit 4; }
	done
}

# p2pdma_pick_members LEVEL  -> sets P2PDMA_M0, P2PDMA_M1, P2PDMA_SUBSTRATE,
# and P2PDMA_LOOPS (for teardown).  Must be called in the current shell (not a
# subshell / process substitution) so the globals are visible to p2pdma_teardown.
# Prefers >=2 *-meshstor-test-* labeled NVMe partitions; else falls back to loop.
p2pdma_pick_members() {
	local labeled=() d
	for d in /dev/disk/by-partlabel/*-meshstor-test-*; do
		[ -e "$d" ] && labeled+=("$d")
	done
	if [ "${#labeled[@]}" -ge 2 ]; then
		P2PDMA_SUBSTRATE=nvme
		P2PDMA_M0="${labeled[0]}"
		P2PDMA_M1="${labeled[1]}"
		return 0
	fi
	P2PDMA_SUBSTRATE=loop
	local i img lo
	for i in 0 1; do
		img="$(mktemp /tmp/p2pdma-loop-XXXX.img)"
		truncate -s 256M "$img"
		lo="$(losetup --find --show "$img")"
		P2PDMA_LOOPS+=("$lo")
		rm -f "$img"   # unlinked; loop holds it
	done
	P2PDMA_M0="${P2PDMA_LOOPS[0]}"
	P2PDMA_M1="${P2PDMA_LOOPS[1]}"
}

# p2pdma_teardown: trap handler -- stop array, detach loops.
p2pdma_teardown() {
	[ -n "$P2PDMA_ARRAY" ] && "$MDADM" --stop "$P2PDMA_ARRAY" >/dev/null 2>&1 || true
	local lo
	for lo in "${P2PDMA_LOOPS[@]}"; do losetup -d "$lo" >/dev/null 2>&1 || true; done
}
