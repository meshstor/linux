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

# Side-file registry.  md_make_loop is called via command substitution
# (loop0="$(md_make_loop 64)"), which runs it in a subshell, so the
# MD_TEST_LOOPS/FILES appends below are LOST in the parent and md_cleanup would
# detach/unlink nothing -- leaking a loop + backing file per call.  A file
# append survives the subshell; record loop+image here and replay it in cleanup.
MD_TEST_REGISTRY="$(mktemp "${MD_TMPDIR:-${TMPDIR:-/var/tmp}}/md-registry.XXXXXX" 2>/dev/null || echo /dev/null)"

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

# Resolve a dd that handles non-page-aligned O_DIRECT buffers.  The Rust
# "uutils" coreutils rewrite ships as the default /usr/bin/dd on some recent
# distros (e.g. Ubuntu's 7.x kernels); its direct-I/O path issues misaligned
# buffers and fails with EINVAL on any sub-page transfer (the bs=4096 probe
# I/O below, etc.), which silently breaks our direct-I/O assertions.  Prefer
# GNU dd: on normal distros the system dd already is GNU and is picked first;
# only on a uutils host do we fall through to gnudd.  Use "$DD", not dd.
_md_resolve_dd() {
	local cand
	for cand in "${DD:-}" gnudd dd; do
		[ -n "$cand" ] || continue
		command -v "$cand" >/dev/null 2>&1 || continue
		"$cand" --version 2>/dev/null | grep -qi 'uutils' && continue
		echo "$cand"; return 0
	done
	echo dd
}
: "${DD:=$(_md_resolve_dd)}"
export DD

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

# md_require_takeover: SKIP unless the running driver supports the raid1 ->
# raid10 takeover this suite exercises.  Under ms it always does (this branch's
# feature), so we short-circuit.  Under MD_SUBSYS=md it depends on the in-tree
# kernel -- stock md rejects the level switch with -EINVAL.  Capability-detected
# by probing a throwaway healthy raid1 (which converts iff the takeover is
# present), so a future in-tree md that gains it runs the suite instead of
# skipping.  Positive tests that convert via md_sysfs_write are auto-skipped
# there and need not call this; the refusal/CLI tests (which EXPECT a refusal
# and so cannot detect absence from "conversion failed") do.
md_require_takeover() {
	[ "$MD_SUBSYS" = ms ] && return 0
	local l0 l1 dev sysfs supported=0
	l0="$(md_make_loop 32)"
	l1="$(md_make_loop 32)"
	dev="$(md_find_free_md_dev)"
	if md_mdadm --create --run --metadata=1.2 --level=1 --raid-devices=2 \
	     "$dev" "$l0" "$l1" >/dev/null 2>&1; then
		md_wait_sync "$dev" >/dev/null 2>&1 || true
		sysfs="$(md_sysfs_path "$dev")"
		local _rc=0
		_md_write_level_raid10 "$sysfs/level" || _rc=$?
		md_mdadm --stop "$dev" >/dev/null 2>&1 || true
		case "$_rc" in
			0) supported=1 ;;
			2) : ;;   # -EINVAL: takeover unsupported -> md_skip below
			*) md_fail "takeover capability probe failed unexpectedly under MD_SUBSYS=md (not -EINVAL: ${MD_LAST_WRITE_ERR:-unknown}) -- not masking" ;;
		esac
	fi
	# The probe's loops are registry-tracked; md_cleanup tears them down at EXIT.
	[ "$supported" = 1 ] || \
		md_skip "raid1->raid10 takeover not supported by the running driver (MD_SUBSYS=$MD_SUBSYS) -- it is a meshstor (ms) feature"
	return 0
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
	# Survives command substitution (the array appends above do not); md_cleanup
	# replays this to tear down loops/files created as loop0="$(md_make_loop)".
	echo "$loop $tmp" >> "${MD_TEST_REGISTRY:-/dev/null}"
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
	# Replay the side-file registry: recover loops/backing files created in
	# command-substitution subshells (loop0="$(md_make_loop)"), where the
	# in-function array appends were lost.  Without this they leak every run.
	local _rl _rf
	if [ -n "${MD_TEST_REGISTRY:-}" ] && [ -r "$MD_TEST_REGISTRY" ]; then
		while read -r _rl _rf; do
			[ -n "$_rl" ] && MD_TEST_LOOPS+=("$_rl")
			[ -n "$_rf" ] && MD_TEST_FILES+=("$_rf")
		done < "$MD_TEST_REGISTRY"
	fi
	local loop tries still
	for loop in "${MD_TEST_LOOPS[@]:-}"; do
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
	for f in "${MD_TEST_FILES[@]:-}"; do
		rm -f "$f"
	done
	rm -f "${MD_TEST_REGISTRY:-}" 2>/dev/null
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
# _md_write_level_raid10 PATH -> attempt the raid1 -> raid10 level switch and
# CLASSIFY the outcome, so callers can tell "takeover unsupported by this
# driver" apart from an unexpected failure that must NOT be masked:
#   0  the switch was accepted
#   2  rejected with -EINVAL ("Invalid argument") -- the target level/takeover
#      is not supported by this driver (feature absent)
#   3  rejected with some OTHER errno (EBUSY/EIO/ENOMEM/...) -- unexpected;
#      MD_LAST_WRITE_ERR holds the errno text
# LC_ALL=C pins the errno string so the match is locale-stable.
MD_LAST_WRITE_ERR=""
_md_write_level_raid10() {
	local path="$1" err
	if err="$( { LC_ALL=C printf '%s\n' raid10 > "$path"; } 2>&1 )"; then
		return 0
	fi
	case "$err" in
		*"Invalid argument"*) return 2 ;;
		*) MD_LAST_WRITE_ERR="${err##*: }"; return 3 ;;
	esac
}

# md_sysfs_write PATH VALUE
md_sysfs_write() {
	local path="$1"
	local value="$2"
	# The raid1 -> raid10 takeover is a meshstor (ms) feature.  Under
	# MD_SUBSYS=md the in-tree driver rejects the level switch.  ONLY -EINVAL
	# means the takeover is unsupported by this driver (feature absent) -> SKIP;
	# any OTHER errno is an unexpected conversion failure that must NOT be masked
	# -> FAIL.  Capability-detected: if a future in-tree md accepts the switch,
	# the write succeeds and the test runs normally.  Inert under ms.
	if [ "$MD_SUBSYS" = md ] && [ "$value" = raid10 ] && [ "${path##*/}" = level ]; then
		local _rc=0
		_md_write_level_raid10 "$path" || _rc=$?
		case "$_rc" in
			0) return 0 ;;
			2) md_skip "raid1->raid10 takeover not supported by the in-tree md driver (MD_SUBSYS=md, -EINVAL) -- it is a meshstor (ms) feature" ;;
			*) md_fail "raid1->raid10 level switch failed unexpectedly under MD_SUBSYS=md (not -EINVAL: ${MD_LAST_WRITE_ERR:-unknown}) -- not masking" ;;
		esac
	fi
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
