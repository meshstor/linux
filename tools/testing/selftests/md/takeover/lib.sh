# SPDX-License-Identifier: GPL-2.0
# Shared helpers for md takeover selftests.
# Sourced by each test_*.sh; never run directly.
#
# By default the tests target the ms stack via /dev/msN (MD_SUBSYS=ms).
# MD_SUBSYS retargets the suite -- MD_SUBSYS=md selects the in-tree md
# driver -- and the individual MD_* / MDADM knobs override the
# per-subsystem defaults when set explicitly, e.g.:
#
#   MD_SUBSYS=ms                   # driver stack under test (the default)
#   MDADM=/usr/local/bin/mdadm     # mdadm binary (the default; PATH fallback)
#   MD_MDADM_SUBSYS=foo            # pass --subsys=foo to mdadm
#                                  # (default $MD_SUBSYS; none under md)
#   MD_DEV_PREFIX=/dev/foo         # device path prefix (default /dev/$MD_SUBSYS)
#   MD_SYSFS_SUBDIR=foo            # /sys/block/<dev>/<subdir> (default $MD_SUBSYS)
#   MD_PROC_STAT=/proc/foostat     # personality file (default /proc/${MD_SUBSYS}stat)

set -u

MD_TEST_LOOPS=()
MD_TEST_FILES=()
MD_TEST_MD_DEV=""

# Side-file registry.  md_make_loop is called with command substitution
# (loop0="$(md_make_loop 64)"), which runs it in a subshell, so the
# MD_TEST_LOOPS/FILES array appends below are LOST in the parent and md_cleanup
# would detach/unlink nothing -- leaking a loop + backing file per call.  A file
# append survives the subshell; record loop+image here and replay it in cleanup.
MD_TEST_REGISTRY="$(mktemp "${MD_TMPDIR:-${TMPDIR:-/var/tmp}}/md-registry.XXXXXX" 2>/dev/null || echo /dev/null)"

# MD_SUBSYS selects the driver stack under test and derives the
# device/sysfs/stat knobs and the mdadm --subsys selector.  'ms' (the
# default) and any other value <s> target an md-compatible stack by
# convention -- /dev/<s>N device nodes, /sys/block/<s>N/<s> sysfs,
# /proc/<s>stat, mdadm --subsys=<s> -- while 'md' selects the in-tree
# driver.  Each MD_* knob still overrides when set explicitly.
MD_SUBSYS="${MD_SUBSYS:-ms}"
if [ "$MD_SUBSYS" = md ]; then
	MD_MDADM_SUBSYS="${MD_MDADM_SUBSYS:-}"
else
	MD_MDADM_SUBSYS="${MD_MDADM_SUBSYS:-$MD_SUBSYS}"
fi
MD_DEV_PREFIX="${MD_DEV_PREFIX:-/dev/$MD_SUBSYS}"
MD_SYSFS_SUBDIR="${MD_SYSFS_SUBDIR:-$MD_SUBSYS}"
MD_PROC_STAT="${MD_PROC_STAT:-/proc/${MD_SUBSYS}stat}"

# Prefer a locally installed mdadm (for an out-of-tree stack, one
# patched to understand --subsys); fall back to the system binary.
if [ -z "${MDADM:-}" ]; then
	MDADM=/usr/local/bin/mdadm
	[ -x "$MDADM" ] || MDADM=mdadm
fi

# Resolve a dd that handles non-page-aligned O_DIRECT buffers.  The Rust
# "uutils" coreutils rewrite ships as the default /usr/bin/dd on some recent
# distros; its direct-I/O path issues misaligned buffers and fails with EINVAL
# on any sub-page transfer (the bs=4096 probe I/O below, etc.), which silently
# breaks the direct-I/O assertions.  Prefer GNU dd: on most distros the system
# dd already is GNU and is picked first; only on a uutils host do we fall
# through to gnudd.  Use "$DD", not dd.
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

# md_mdadm ARGS... -> mdadm with the subsystem selector baked in.
md_mdadm() {
	if [ -n "$MD_MDADM_SUBSYS" ]; then
		"$MDADM" --subsys="$MD_MDADM_SUBSYS" "$@"
	else
		"$MDADM" "$@"
	fi
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
	if ! command -v "$MDADM" >/dev/null 2>&1 && ! [ -x "$MDADM" ]; then
		echo "SKIP: missing mdadm at: $MDADM" >&2
		exit 4
	fi
	# An out-of-tree stack needs an mdadm patched to understand --subsys;
	# a stock mdadm rejects it with "unrecognized option".
	if [ -n "$MD_MDADM_SUBSYS" ] && \
	   ! "$MDADM" --subsys="$MD_MDADM_SUBSYS" --version >/dev/null 2>&1; then
		echo "SKIP: $MDADM does not understand --subsys=$MD_MDADM_SUBSYS" >&2
		exit 4
	fi
}

md_require_modules() {
	# Personality file first line: "Personalities : [raid1] [raid10]".
	# Load the in-tree modules first if need be; built-in or already
	# registered personalities make that a no-op, and an out-of-tree
	# stack ships its own modules, so a modprobe failure is not an
	# error -- the registration check below is what decides.
	modprobe -qa raid1 raid10 2>/dev/null || true
	local p
	for p in raid1 raid10; do
		if ! head -1 "$MD_PROC_STAT" 2>/dev/null | grep -qw "$p"; then
			echo "SKIP: $p personality not registered in $MD_PROC_STAT" >&2
			exit 4
		fi
	done
}

# md_require_takeover: SKIP unless the running driver supports the raid1 ->
# raid10 takeover this suite exercises -- a kernel without it rejects the
# level switch with -EINVAL.  Capability-detected by probing a throwaway
# healthy raid1 (which converts iff the takeover is present), so the suite
# keys off the running driver rather than a version or subsystem name.
# Positive tests that convert via md_sysfs_write are auto-skipped there and
# need not call this; the refusal/CLI tests (which EXPECT a refusal and so
# cannot detect absence from "conversion failed") do.
md_require_takeover() {
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
			*) md_fail "takeover capability probe failed unexpectedly (not -EINVAL: ${MD_LAST_WRITE_ERR:-unknown}) -- not masking" ;;
		esac
	fi
	# The probe's loops are registry-tracked; md_cleanup tears them down at EXIT.
	[ "$supported" = 1 ] || \
		md_skip "raid1->raid10 takeover not supported by the running driver"
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
# selected subsystem (e.g. /dev/mdNNN).
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

# md_sysfs_path MD_DEV -> echoes /sys/block/<name>/<MD_SYSFS_SUBDIR>
md_sysfs_path() {
	local dev="$1"
	local name
	name="$(basename "$dev")"
	echo "/sys/block/$name/$MD_SYSFS_SUBDIR"
}

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
	# A kernel without the raid1 -> raid10 takeover rejects the level
	# switch.  ONLY -EINVAL means the takeover is unsupported by the
	# running driver (feature absent) -> SKIP; any OTHER errno is an
	# unexpected conversion failure that must NOT be masked -> FAIL.
	# Capability-detected: when the driver supports the takeover the
	# write succeeds and the test runs normally.
	if [ "$value" = raid10 ] && [ "${path##*/}" = level ]; then
		local _rc=0
		_md_write_level_raid10 "$path" || _rc=$?
		case "$_rc" in
			0) return 0 ;;
			2) md_skip "raid1->raid10 takeover not supported by the running driver (-EINVAL)" ;;
			*) md_fail "raid1->raid10 level switch failed unexpectedly (not -EINVAL: ${MD_LAST_WRITE_ERR:-unknown}) -- not masking" ;;
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
# the resync thread finishes -- and on fast loop-backed members
# mdadm --wait can return before any resync ticks at all. Poll
# sync_action directly until it reads "idle" so the level write in
# the next step can proceed.
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
