# SPDX-License-Identifier: GPL-2.0
# Shared helpers for llbitmap selftests.
#
# A single knob, MD_SUBSYS, selects the subsystem and derives the device
# prefix, sysfs subdir, personality (/proc) file and core/raid1 module names
# -- matching the takeover/, raid10/ and latency/ suites so one MD_SUBSYS=ms
# (the default) drives the whole composed md selftest tree.
#
#   MD_SUBSYS=ms (default) -> out-of-tree meshstor-ms build, which renames
#                md-* to ms-* so it can coexist with the in-kernel md_mod
#                (built into vmlinuz on RHEL 10.x / Ubuntu). Devices are
#                /dev/msN (major 252) under /sys/block/msN/ms, personalities
#                in /proc/msstat, modules ms_mod.ko + raid1_ms.ko loaded.
#   MD_SUBSYS=md           -> in-tree md driver (stock /dev/mdN,
#                /sys/block/mdN/md, /proc/mdstat, built-in md_mod + raid1).
#
# BOTH subsystems need the meshstor-patched mdadm: the llbitmap arrays are
# created with --bitmap=lockless, which the stock distro mdadm does not
# understand. The patched mdadm infers the subsystem from the device-name
# prefix (msN -> major 252, mdN -> major 9), so no --subsys flag is needed.
#
# Sourced by each test_*.sh under this directory; never run directly.

set -u

# MD_SUBSYS selects the subsystem and derives the per-subsystem knobs.
MD_SUBSYS="${MD_SUBSYS:-ms}"
case "$MD_SUBSYS" in
ms)
	LLBITMAP_DEV_PREFIX="ms"	# /dev/msN
	LLBITMAP_SYSFS_SUBDIR="ms"	# /sys/block/msN/ms
	LLBITMAP_PROC_STAT="/proc/msstat"
	LLBITMAP_CORE_MOD="ms_mod"
	LLBITMAP_RAID1_MOD="raid1_ms"
	;;
md)
	LLBITMAP_DEV_PREFIX="md"	# /dev/mdN
	LLBITMAP_SYSFS_SUBDIR="md"	# /sys/block/mdN/md
	LLBITMAP_PROC_STAT="/proc/mdstat"
	LLBITMAP_CORE_MOD="md_mod"
	LLBITMAP_RAID1_MOD="raid1"
	;;
*)
	echo "FAIL: unknown MD_SUBSYS=$MD_SUBSYS (want 'ms' or 'md')" >&2
	exit 1
	;;
esac

# Path to the meshstor-patched mdadm (understands --bitmap=lockless and the
# msN device-name prefix); required for BOTH subsystems. Override via MDADM=...
MDADM="${MDADM:-/home/mykola/mdadm/mdadm}"

# Resolve a dd that handles non-page-aligned O_DIRECT buffers.  The Rust
# "uutils" coreutils rewrite ships as the default /usr/bin/dd on some recent
# distros (e.g. Ubuntu's 7.x kernels); its direct-I/O path issues misaligned
# buffers and fails with EINVAL on any sub-page transfer (bs=4096 reads, etc.),
# which silently breaks our direct-I/O readback assertions.  Prefer GNU dd: on
# normal distros the system dd already is GNU and is picked first; only on a
# uutils host do we fall through to gnudd.  Tests must invoke "$DD", not dd.
_llbitmap_resolve_dd() {
	local cand
	for cand in "${DD:-}" gnudd dd; do
		[ -n "$cand" ] || continue
		command -v "$cand" >/dev/null 2>&1 || continue
		"$cand" --version 2>/dev/null | grep -qi 'uutils' && continue
		echo "$cand"; return 0
	done
	echo dd
}
: "${DD:=$(_llbitmap_resolve_dd)}"
export DD

LLBITMAP_TEST_LOOPS=()
LLBITMAP_TEST_FILES=()
LLBITMAP_TEST_MS_DEV=""
LLBITMAP_TEST_MS_NAME=""
LLBITMAP_TEST_MOUNT=""

llbitmap_require_root() {
	if [ "$(id -u)" -ne 0 ]; then
		echo "SKIP: must run as root (try: sudo $0)" >&2
		exit 4
	fi
}

llbitmap_require_modules() {
	if [ ! -x "$MDADM" ]; then
		echo "SKIP: meshstor mdadm not found at $MDADM" >&2
		exit 4
	fi
	# Both subsystems create llbitmap arrays with --bitmap=lockless; the
	# stock distro mdadm lacks that option. Probe for it when we can so
	# the skip message is clear (otherwise every --create just fails).
	if command -v strings >/dev/null 2>&1 \
	   && ! strings "$MDADM" 2>/dev/null | grep -qiw lockless; then
		echo "SKIP: $MDADM lacks --bitmap=lockless support (need patched mdadm)" >&2
		exit 4
	fi
	if [ "$MD_SUBSYS" = ms ]; then
		# Out-of-tree modules must be explicitly loaded.
		if ! lsmod | grep -q "^${LLBITMAP_CORE_MOD} "; then
			echo "SKIP: ${LLBITMAP_CORE_MOD} not loaded" >&2
			exit 4
		fi
		if ! lsmod | grep -q "^${LLBITMAP_RAID1_MOD} "; then
			echo "SKIP: ${LLBITMAP_RAID1_MOD} not loaded" >&2
			exit 4
		fi
	else
		# In-tree md core is typically built into vmlinux (absent from
		# lsmod); the sysfs module dir is the portable presence signal.
		if [ ! -d "/sys/module/${LLBITMAP_CORE_MOD}" ]; then
			echo "SKIP: ${LLBITMAP_CORE_MOD} not present" >&2
			exit 4
		fi
	fi
}

llbitmap_require_tools() {
	local tool
	for tool in losetup dd dmesg od; do
		if ! command -v "$tool" >/dev/null 2>&1; then
			echo "SKIP: missing tool: $tool" >&2
			exit 4
		fi
	done
}

# llbitmap_make_loop SIZE_MB -> echoes loop device path
llbitmap_make_loop() {
	local size_mb="$1"
	local tmp
	tmp="$(mktemp "${TMPDIR:-/tmp}/llbitmap-selftest.XXXXXX.img")"
	truncate -s "${size_mb}M" "$tmp"
	local loop
	loop="$(losetup -f --show "$tmp")"
	LLBITMAP_TEST_LOOPS+=("$loop")
	LLBITMAP_TEST_FILES+=("$tmp")
	echo "$loop"
}

# llbitmap_alloc_ms_dev: pick an unused device name for the selected
# subsystem (/dev/msN or /dev/mdN), set the globals LLBITMAP_TEST_MS_DEV and
# LLBITMAP_TEST_MS_NAME, and echo the path. mdadm --create will create the
# device node itself. We deliberately do NOT precreate via
# /sys/module/<core>/parameters/new_array because that path leaves the device
# in a state where mdadm assemble silently bypasses bitmap revalidation
# (observed: a corrupted bitmap super that should EINVAL is accepted instead).
#
# The MS_ in the global names is historical; under MD_SUBSYS=md they hold the
# /dev/mdN path/name. Globals do NOT propagate out of $(...) subshells, so the
# caller must additionally set LLBITMAP_TEST_MS_DEV itself or call this without
# command substitution.
llbitmap_alloc_ms_dev() {
	local n
	for n in $(seq 200 250); do
		local dev="/dev/${LLBITMAP_DEV_PREFIX}${n}"
		local name="${LLBITMAP_DEV_PREFIX}${n}"
		# Ensure no existing array AND no leftover device node.
		# If a stale node exists, stop any array on it and remove
		# the node so mdadm can create a fresh one.
		if [ -b "$dev" ]; then
			"$MDADM" --stop "$dev" >/dev/null 2>&1 || true
			# array_state=clear means no array is running.
			local state
			state=$(cat "/sys/block/${name}/${LLBITMAP_SYSFS_SUBDIR}/array_state" 2>/dev/null || echo "")
			if [ "$state" = "clear" ] || [ -z "$state" ]; then
				# Acceptable: stale device node, mdadm will reuse it.
				:
			else
				continue
			fi
		fi
		LLBITMAP_TEST_MS_DEV="$dev"
		LLBITMAP_TEST_MS_NAME="$name"
		echo "$dev"
		return 0
	done
	echo "FAIL: no free ${LLBITMAP_DEV_PREFIX} device in 200-250 range" >&2
	exit 1
}

llbitmap_cleanup() {
	set +e
	if [ -n "$LLBITMAP_TEST_MOUNT" ] && mountpoint -q "$LLBITMAP_TEST_MOUNT" 2>/dev/null; then
		umount "$LLBITMAP_TEST_MOUNT" >/dev/null 2>&1
		rmdir "$LLBITMAP_TEST_MOUNT" >/dev/null 2>&1
	fi
	if [ -n "$LLBITMAP_TEST_MS_DEV" ] && [ -b "$LLBITMAP_TEST_MS_DEV" ]; then
		"$MDADM" --stop "$LLBITMAP_TEST_MS_DEV" >/dev/null 2>&1
	fi
	udevadm settle >/dev/null 2>&1
	local loop tries still
	for loop in "${LLBITMAP_TEST_LOOPS[@]:-}"; do
		losetup -d "$loop" >/dev/null 2>&1
	done
	for tries in $(seq 1 50); do
		still=0
		for loop in "${LLBITMAP_TEST_LOOPS[@]:-}"; do
			if losetup -a 2>/dev/null | grep -q "^$loop:"; then
				still=1
				losetup -d "$loop" >/dev/null 2>&1
			fi
		done
		[ "$still" -eq 0 ] && break
		sleep 0.1
	done
	local f
	for f in "${LLBITMAP_TEST_FILES[@]:-}"; do
		rm -f "$f"
	done
	set -e
}

trap llbitmap_cleanup EXIT

# llbitmap_dmesg_contains PATTERN -> exit 0 if found in last 200 lines
llbitmap_dmesg_contains() {
	dmesg | tail -200 | grep -q "$1"
}

# llbitmap_dmesg_clear: best-effort clear (root only)
llbitmap_dmesg_clear() {
	dmesg --clear >/dev/null 2>&1 || true
}

# llbitmap_stop_inkernel_md MEMBER... -> stop any IN-TREE md array that udev
# auto-assembled over our loop/dm members.  meshstor superblocks are bit-for-bit
# identical to kernel md, so under MD_SUBSYS=ms the in-tree md_mod grabs the
# members the moment they reappear (after a --stop or a dmsetup create/resume),
# holding them busy and shadowing a direct read of the underlying loops.  The
# 'md*' holder glob matches only in-tree md arrays (our personality is msNNN),
# so this never stops OUR array.  A no-op under MD_SUBSYS=md (our array *is* the
# md* holder -- but there the bit-identical-superblock theft cannot occur).
llbitmap_stop_inkernel_md() {
	[ "$MD_SUBSYS" = ms ] || return 0
	local memb base h hname
	for memb in "$@"; do
		[ -n "$memb" ] && [ -e "$memb" ] || continue
		base=$(basename "$(readlink -f "$memb")")
		for h in /sys/block/"$base"/holders/md*; do
			[ -e "$h" ] || continue
			hname=$(basename "$h")
			"$MDADM" --stop "/dev/$hname" >/dev/null 2>&1 || true
		done
	done
	udevadm settle 2>/dev/null || true
}

# llbitmap_state_count MS_NAME STATE -> integer chunk count in given state
# Reads from /sys/block/<ms>/ms/llbitmap/bits which prints lines like:
#   unwritten N
#   clean N
#   dirty N
#   need sync N
#   syncing N
#   ...
llbitmap_state_count() {
	local ms_name="$1"
	local state="$2"
	awk -v s="$state" '$0 ~ "^"s" "{print $NF; found=1; exit} END{if (!found) print "0"}' \
		"/sys/block/${ms_name}/${LLBITMAP_SYSFS_SUBDIR}/llbitmap/bits"
}

# llbitmap_member_state MS_NAME MEMBER -> contents of dev-<member>/state
llbitmap_member_state() {
	cat "/sys/block/$1/${LLBITMAP_SYSFS_SUBDIR}/dev-$2/state" 2>/dev/null || echo "missing"
}

llbitmap_pass() { echo "PASS: $1"; exit 0; }
llbitmap_fail() { echo "FAIL: $1" >&2; exit 1; }
llbitmap_skip() { echo "SKIP: $1" >&2; exit 4; }

# llbitmap_events_of LOOP_OR_BLOCK -> echoes the integer events counter
# from `mdadm --examine`. mdadm prints lines like
#       Events :     17
# We strip leading whitespace and the field separator, then trim.
# Returns "" and exits 1 if mdadm fails or the field isn't found.
llbitmap_events_of() {
	local dev="$1"
	local line
	line="$("$MDADM" --examine "$dev" 2>/dev/null | awk -F: '/^[ \t]*Events[ \t]*:/{gsub(/[ \t]/, "", $2); print $2; exit}')" || true
	if [ -z "$line" ]; then
		echo "FAIL: llbitmap_events_of: no Events field for $dev" >&2
		return 1
	fi
	echo "$line"
}

# llbitmap_member_present MS_NAME MEMBER_BASENAME -> 0 if the member is
# tracked by sysfs (state file exists and is non-empty), 1 otherwise.
# After `kicking non-fresh`, the member's dev-<X> directory is gone.
llbitmap_member_present() {
	local ms_name="$1"
	local member="$2"
	local state_file="/sys/block/${ms_name}/${LLBITMAP_SYSFS_SUBDIR}/dev-${member}/state"
	[ -r "$state_file" ] && [ -n "$(cat "$state_file" 2>/dev/null)" ]
}
