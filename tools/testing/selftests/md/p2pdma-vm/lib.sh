# SPDX-License-Identifier: GPL-2.0
# Shared helpers for the p2pdma Layer-B (non-P2P control) selftests.
# Targets the meshstor-ms out-of-tree build (ms_*; /dev/msN, major ~252).
# Sourced by each test_*.sh; never run directly. Exit: 0 pass, 1 fail, 4 skip.
set -u

MDADM="${MDADM:-/home/mykola/mdadm/mdadm}"
# O_DIRECT-capable dd: Ubuntu 26.04+ makes /usr/bin/dd the Rust uutils rewrite,
# whose O_DIRECT buffer alignment fails on md/ms queues (dma_alignment=511) while
# working on raw NVMe — a false failure in any direct-I/O assertion. Prefer the
# GNU binary the distro ships alongside.
DD="${DD:-$( [ -x /usr/bin/gnudd ] && echo /usr/bin/gnudd || echo dd )}"
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

# _p2pdma_backing_is_live_md DEVNODE  -> returns 0 (true) when the resolved
# block device (the partition ITSELF or its parent disk) is an active member in
# /proc/mdstat.  Root-on-md protection: a stale *-meshstor-test-* label can point
# at a partition that currently backs a LIVE (possibly root) md array; handing it
# to a test that later --zero-superblock's it would corrupt that array.
_p2pdma_backing_is_live_md() {
	local node kn syslink parent
	node="$(realpath "$1" 2>/dev/null)" || return 1
	kn="$(basename "$node")"
	# md members appear as "<kname>[<role>]" in /proc/mdstat
	grep -Eq "(^|[[:space:]])${kn}\[[0-9]+\]" /proc/mdstat 2>/dev/null && return 0
	# also refuse if the PARENT disk is itself a whole-disk md member
	syslink="$(realpath "/sys/class/block/$kn" 2>/dev/null)" || return 1
	parent="$(basename "$(dirname "$syslink")")"
	case "$parent" in ""|"."|block|"$kn") return 1;; esac
	grep -Eq "(^|[[:space:]])${parent}\[[0-9]+\]" /proc/mdstat 2>/dev/null && return 0
	return 1
}

# p2pdma_pick_members LEVEL  -> sets P2PDMA_M0, P2PDMA_M1, P2PDMA_SUBSTRATE,
# and P2PDMA_LOOPS (for teardown).  Must be called in the current shell (not a
# subshell / process substitution) so the globals are visible to p2pdma_teardown.
# Prefers >=2 *-meshstor-test-* labeled NVMe partitions; else falls back to loop.
# Never selects a label backing a LIVE md array member; if enough labels exist
# but too few are safe, SKIPs (exit 4) rather than risk a live (root) array.
p2pdma_pick_members() {
	local level="${1:-raid1}" need
	case "$level" in raid10) need=4;; *) need=2;; esac
	local labeled=() total=0 d
	for d in /dev/disk/by-partlabel/*-meshstor-test-*; do
		[ -e "$d" ] || continue
		total=$((total + 1))
		if _p2pdma_backing_is_live_md "$d"; then
			echo "note: $d backs a live md array member — excluded from selection" >&2
			continue
		fi
		labeled+=("$d")
	done
	if [ "${#labeled[@]}" -ge "$need" ]; then
		P2PDMA_SUBSTRATE=nvme
		P2PDMA_M0="${labeled[0]}"
		P2PDMA_M1="${labeled[1]}"
		return 0
	fi
	# Enough labeled test partitions exist, but too few are SAFE (some back a
	# live array) — refuse outright rather than fall through to a live member
	# or a silent loop downgrade.
	if [ "$total" -ge "$need" ]; then
		echo "SKIP: fewer than $need free test partitions (some -meshstor-test- labels back a live md array)" >&2
		exit 4
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
