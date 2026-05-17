# SPDX-License-Identifier: GPL-2.0
# Shared helpers for md selftests.
# Sourced by each test_*.sh; never run directly.
#
# These tests exercise the out-of-tree raid1_ms / raid10_ms / ms_mod
# modules from this branch. mdadm is driven with --subsys=ms so that
# arrays land on /dev/ms* (major 252) under /sys/block/ms*/ms/* rather
# than the in-tree md framework. The MD_SUBSYS variable lets a future
# test bench point the same scaffolding at /dev/md* by exporting
# MD_SUBSYS=md before sourcing.

set -u

MD_TEST_LOOPS=()
MD_TEST_FILES=()
MD_TEST_MD_DEV=""

# Subsystem selector. "ms" -> _ms modules; "md" -> in-tree md.
MD_SUBSYS="${MD_SUBSYS:-ms}"
case "$MD_SUBSYS" in
	ms)
		MD_DEV_PREFIX="/dev/ms"
		MD_DEVNM_PREFIX="ms"
		MD_SYSFS_SUBDIR="ms"
		MD_PROC_STAT="/proc/msstat"
		;;
	md)
		MD_DEV_PREFIX="/dev/md"
		MD_DEVNM_PREFIX="md"
		MD_SYSFS_SUBDIR="md"
		MD_PROC_STAT="/proc/mdstat"
		;;
	*)
		echo "FAIL: unknown MD_SUBSYS=$MD_SUBSYS" >&2
		exit 1
		;;
esac

# Path to the in-tree-patched mdadm binary. Override via MDADM=...
MDADM="${MDADM:-/home/mykola/mdadm/mdadm}"

# md_mdadm ARGS... -> mdadm with the right subsys baked in.
md_mdadm() {
	"$MDADM" --subsys="$MD_SUBSYS" "$@"
}

md_require_root() {
	if [ "$(id -u)" -ne 0 ]; then
		echo "SKIP: must run as root" >&2
		exit 4
	fi
}

md_require_tools() {
	local tool
	for tool in losetup dd md5sum dmesg; do
		if ! command -v "$tool" >/dev/null 2>&1; then
			echo "SKIP: missing tool: $tool" >&2
			exit 4
		fi
	done
	if [ ! -x "$MDADM" ]; then
		echo "SKIP: missing mdadm at $MDADM" >&2
		exit 4
	fi
	# Verify the subsys-aware mdadm; the in-tree mdadm without the
	# patches will reject --subsys=ms with "unrecognized option".
	if ! "$MDADM" --subsys="$MD_SUBSYS" --version >/dev/null 2>&1; then
		echo "SKIP: $MDADM does not understand --subsys=$MD_SUBSYS" >&2
		exit 4
	fi
}

md_require_modules() {
	# Only meaningful when targetting the ms subsystem.
	[ "$MD_SUBSYS" = "ms" ] || return 0
	local m
	for m in ms_mod raid1_ms raid10_ms; do
		if [ ! -d "/sys/module/$m" ]; then
			echo "SKIP: required kernel module not loaded: $m" >&2
			exit 4
		fi
	done
}

# md_make_loop SIZE_MB -> echoes loop device path
#
# Default scratch dir is /var/tmp rather than /tmp because /tmp is
# tmpfs on most distros and the suite quickly exceeds its size: 26
# tests * ~3 loops * 64-96 MB each = several GiB.
md_make_loop() {
	local size_mb="$1"
	local tmp
	tmp="$(mktemp "${MD_TMPDIR:-${TMPDIR:-/var/tmp}}/md-selftest.XXXXXX.img")"
	truncate -s "${size_mb}M" "$tmp"
	local loop
	loop="$(losetup -f --show "$tmp")"
	MD_TEST_LOOPS+=("$loop")
	MD_TEST_FILES+=("$tmp")
	echo "$loop"
}

# md_cleanup: stop arrays, detach loops, unlink backing files.
# losetup -d reports success even when systemd-udev still holds the
# device open; in that case the loop enters LO_FLAGS_AUTOCLEAR and the
# backing file stays pinned until udev drops its fd. On tmpfs-backed
# scratch dirs (e.g. /var/tmp in a vng guest) the leaked files quickly
# push later tests into ENOSPC, so poll `losetup -a` until every loop
# this test allocated has actually gone away.
md_cleanup() {
	set +e
	if [ -n "$MD_TEST_MD_DEV" ] && [ -b "$MD_TEST_MD_DEV" ]; then
		md_mdadm --stop "$MD_TEST_MD_DEV" >/dev/null 2>&1
	fi
	udevadm settle >/dev/null 2>&1
	local loop tries still
	for loop in "${MD_TEST_LOOPS[@]}"; do
		losetup -d "$loop" >/dev/null 2>&1
	done
	for tries in $(seq 1 50); do
		still=0
		for loop in "${MD_TEST_LOOPS[@]}"; do
			if losetup -a 2>/dev/null | grep -q "^$loop:"; then
				still=1
				losetup -d "$loop" >/dev/null 2>&1
			fi
		done
		[ "$still" -eq 0 ] && break
		sleep 0.1
	done
	local f
	for f in "${MD_TEST_FILES[@]}"; do
		rm -f "$f"
	done
	set -e
}

trap md_cleanup EXIT

# md_find_free_md_dev: echo the next unused device path for the
# selected subsystem (/dev/msNNN or /dev/mdNNN).
md_find_free_md_dev() {
	local n=127
	while [ -e "${MD_DEV_PREFIX}${n}" ]; do
		n=$((n - 1))
		if [ $n -lt 100 ]; then
			echo "FAIL: no free md device" >&2
			exit 1
		fi
	done
	echo "${MD_DEV_PREFIX}${n}"
}

# md_sysfs_path MD_DEV -> echoes /sys/block/<name>/{md,ms}
md_sysfs_path() {
	local dev="$1"
	local name
	name="$(basename "$dev")"
	echo "/sys/block/$name/$MD_SYSFS_SUBDIR"
}

# md_sysfs_write PATH VALUE
md_sysfs_write() {
	local path="$1"
	local value="$2"
	echo "$value" > "$path"
}

# md_sysfs_read PATH
md_sysfs_read() {
	cat "$1"
}

# md_dmesg_contains PATTERN -> exit 0 if found
md_dmesg_contains() {
	dmesg | tail -400 | grep -q "$1"
}

# md_wait_sync MD_DEV -> block until recovery/resync drains.
# Fresh raid1 arrays kick off an initial sync that holds
# MD_RECOVERY_RUNNING, which level_store() rejects with EBUSY. Call
# this after create to make the array quiescent.
#
# `mdadm --wait` returns as soon as the array is fully in_sync, but
# the kernel may still be holding MD_RECOVERY_RUNNING briefly after
# the resync thread finishes — and on the lockless _ms framework
# mdadm --wait sometimes returns before any resync ticks at all.
# Poll sync_action directly until it reads "idle" so the level write
# in the next step can proceed.
md_wait_sync() {
	local dev="$1"
	local sysfs
	sysfs="$(md_sysfs_path "$dev")"
	md_mdadm --wait "$dev" >/dev/null 2>&1 || true
	local i action
	for i in $(seq 1 600); do
		action="$(cat "$sysfs/sync_action" 2>/dev/null || echo idle)"
		[ "$action" = "idle" ] && return 0
		sleep 0.1
	done
	echo "md_wait_sync: sync_action still '$action' after 60s" >&2
	return 1
}

# md_clear_dmesg: drop kernel ring buffer noise from earlier tests so
# pr_warn checks in this test do not match leftovers.
md_clear_dmesg() {
	dmesg -c >/dev/null 2>&1 || true
}

md_pass() { echo "PASS: $1"; exit 0; }
md_fail() { echo "FAIL: $1" >&2; exit 1; }
md_skip() { echo "SKIP: $1" >&2; exit 4; }
