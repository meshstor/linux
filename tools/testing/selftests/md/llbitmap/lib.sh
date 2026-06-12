# SPDX-License-Identifier: GPL-2.0
# Shared helpers for llbitmap selftests.
#
# These tests target the meshstor-ms out-of-tree build, which renames md-* to
# ms-* so it can coexist with the in-kernel md_mod (built into vmlinuz on RHEL
# 10.x). Devices are /dev/msN with major 252.
#
# The test environment requires:
#   - ms_mod.ko + raid1_ms.ko built and loaded
#       (build dir: build/linux-meshstor-rebuilt/build/meshstor-ms-0.1.0-baseline)
#   - /home/mykola/mdadm/mdadm — meshstor-patched mdadm that recognises
#       major 252 as an MD-class device. The system /usr/sbin/mdadm rejects
#       /dev/msN as "not an md device".
#
# Sourced by each test_*.sh under this directory; never run directly.

set -u

# Path to the meshstor-patched mdadm (recognises /dev/msN).
MDADM="${MDADM:-/home/mykola/mdadm/mdadm}"

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
	if ! lsmod | grep -q '^ms_mod '; then
		echo "SKIP: ms_mod not loaded" >&2
		exit 4
	fi
	if ! lsmod | grep -q '^raid1_ms '; then
		echo "SKIP: raid1_ms not loaded" >&2
		exit 4
	fi
	if [ ! -x "$MDADM" ]; then
		echo "SKIP: meshstor mdadm not found at $MDADM" >&2
		exit 4
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

# llbitmap_alloc_ms_dev: pick an unused ms device name (not yet allocated),
# set the globals LLBITMAP_TEST_MS_DEV and LLBITMAP_TEST_MS_NAME, and echo
# the path. mdadm --create will create the device node itself. We
# deliberately do NOT precreate via /sys/module/ms_mod/parameters/new_array
# because that path leaves the device in a state where mdadm assemble
# silently bypasses bitmap revalidation (observed: a corrupted bitmap
# super that should EINVAL is accepted instead).
#
# Globals do NOT propagate out of $(...) subshells, so the caller must
# additionally set LLBITMAP_TEST_MS_DEV itself or call this without
# command substitution.
llbitmap_alloc_ms_dev() {
	local n
	for n in $(seq 200 250); do
		# Ensure no existing array AND no leftover device node.
		# If a stale node exists, stop any array on it and remove
		# the node so mdadm can create a fresh one.
		if [ -b "/dev/ms${n}" ]; then
			"$MDADM" --stop "/dev/ms${n}" >/dev/null 2>&1 || true
			# array_state=clear means no array is running.
			local state
			state=$(cat "/sys/block/ms${n}/ms/array_state" 2>/dev/null || echo "")
			if [ "$state" = "clear" ] || [ -z "$state" ]; then
				# Acceptable: stale device node, mdadm will reuse it.
				:
			else
				continue
			fi
		fi
		LLBITMAP_TEST_MS_DEV="/dev/ms${n}"
		LLBITMAP_TEST_MS_NAME="ms${n}"
		echo "/dev/ms${n}"
		return 0
	done
	echo "FAIL: no free ms device in 200-250 range" >&2
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
		"/sys/block/${ms_name}/ms/llbitmap/bits"
}

# llbitmap_member_state MS_NAME MEMBER -> contents of dev-<member>/state
llbitmap_member_state() {
	cat "/sys/block/$1/ms/dev-$2/state" 2>/dev/null || echo "missing"
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
	local state_file="/sys/block/${ms_name}/ms/dev-${member}/state"
	[ -r "$state_file" ] && [ -n "$(cat "$state_file" 2>/dev/null)" ]
}
