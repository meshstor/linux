# SPDX-License-Identifier: GPL-2.0
# Shared helpers for raid10 selftests.
#
# A single knob, MD_SUBSYS, selects the subsystem and derives the device
# prefix, sysfs subdir, personality file and mdadm -- matching ../lib.sh.
#
#   MD_SUBSYS=ms (default) -> out-of-tree meshstor-ms raid10_ms.ko (under
#                ms_mod.ko, major 252, devices /dev/msN, /sys/block/msN/ms,
#                /proc/msstat, patched mdadm).
#   MD_SUBSYS=md           -> in-tree md/raid10 driver (stock /dev/mdN).
#
# ms is the default so a bare run validates the meshstor product.  md is
# opt-in: test_recovery_freeze_deadlock.sh HARD-WEDGES the in-tree driver
# (unkillable D-state kthreads, reboot to clear) because it lacks the
# per-bucket-arrays fix; raid10_ms carries that fix and survives the test.
#
# The individual RAID10_DEV_PREFIX / RAID10_SYSFS_SUBDIR / RAID10_MDSTAT /
# MDADM vars below still override the derived values when set explicitly.
#
# Loop devices on tmpfs back the array so storage is fast enough that
# barrier-path lock contention is the dominant cost.

set -u

MD_SUBSYS="${MD_SUBSYS:-ms}"
case "$MD_SUBSYS" in
	ms)
		RAID10_DEV_PREFIX="${RAID10_DEV_PREFIX:-ms}"
		RAID10_SYSFS_SUBDIR="${RAID10_SYSFS_SUBDIR:-ms}"
		RAID10_MDSTAT="${RAID10_MDSTAT:-/proc/msstat}"
		MDADM="${MDADM:-/home/mykola/mdadm/mdadm}"
		;;
	md)
		RAID10_DEV_PREFIX="${RAID10_DEV_PREFIX:-md}"
		RAID10_SYSFS_SUBDIR="${RAID10_SYSFS_SUBDIR:-md}"
		RAID10_MDSTAT="${RAID10_MDSTAT:-/proc/mdstat}"
		MDADM="${MDADM:-mdadm}"
		;;
	*)
		echo "FAIL: unknown MD_SUBSYS=$MD_SUBSYS (want 'ms' or 'md')" >&2
		exit 1
		;;
esac

RAID10_TEST_LOOPS=()
RAID10_TEST_FILES=()
RAID10_TEST_MD=""

raid10_require_root() {
	if [ "$(id -u)" -ne 0 ]; then
		echo "SKIP: must run as root (try: sudo $0)" >&2
		exit 4
	fi
}

raid10_require_tools() {
	local tool
	for tool in losetup fio python3; do
		if ! command -v "$tool" >/dev/null 2>&1; then
			echo "SKIP: missing tool: $tool" >&2
			exit 4
		fi
	done
	if ! command -v "$MDADM" >/dev/null 2>&1 && ! [ -x "$MDADM" ]; then
		echo "SKIP: missing mdadm at: $MDADM" >&2
		exit 4
	fi
}

raid10_require_module() {
	# Personality file first line: "Personalities : [raid1] [raid10]"
	if ! head -1 "$RAID10_MDSTAT" 2>/dev/null | grep -qw raid10; then
		echo "SKIP: raid10 personality not registered in $RAID10_MDSTAT" >&2
		exit 4
	fi
}

# raid10_require_tmpfs DIR [NEED_KB] -- DIR must be tmpfs/ramfs with at
# least NEED_KB free (default 10 GB for callers that don't size their
# footprint).  Plain shell arithmetic: no bc dependency.
raid10_require_tmpfs() {
	local dir="${1:-/dev/shm}" need_kb="${2:-$((10 * 1024 * 1024))}"
	local fs
	fs=$(stat -f -c '%T' "$dir" 2>/dev/null || echo unknown)
	case "$fs" in
		tmpfs|ramfs) : ;;
		*)
			echo "SKIP: $dir is not tmpfs/ramfs (got $fs) -- backing store too slow" >&2
			exit 4
			;;
	esac
	local blocks bsize free_kb
	read -r blocks bsize <<< "$(stat -f -c '%a %S' "$dir" 2>/dev/null || echo 0 0)"
	free_kb=$((blocks * bsize / 1024))
	if [ "$free_kb" -lt "$need_kb" ]; then
		echo "SKIP: $dir has ${free_kb} kB free, need ${need_kb} kB" >&2
		exit 4
	fi
}

# raid10_size_to_kb SIZE -- convert an iec size ("2G") to kB.
raid10_size_to_kb() {
	echo $(($(numfmt --from=iec "$1") / 1024))
}

# raid10_make_loop DIR SIZE -> echoes loop device path.
# SIZE is anything truncate accepts (e.g. "2G").  Callers MUST also call
# raid10_register_loop with the returned loop+image so cleanup picks them
# up -- this function runs inside command substitution and cannot update
# RAID10_TEST_LOOPS / RAID10_TEST_FILES in the parent shell itself.
raid10_make_loop() {
	local dir="$1" size="$2"
	local tmp
	tmp="$(mktemp "${dir}/raid10-selftest.XXXXXX.img")"
	truncate -s "$size" "$tmp"
	local loop
	loop="$(losetup -f --show "$tmp")"
	# Record the backing file in a side file so the parent shell can
	# recover it after subshell exit.  Each line is: <loop> <image>
	echo "$loop $tmp" >> "${RAID10_TEST_REGISTRY:-/dev/null}"
	echo "$loop"
}

# raid10_init_registry -- create the side-file the parent uses to track
# loops/files created in subshells.  Must be called once, before any
# raid10_make_loop.
raid10_init_registry() {
	RAID10_TEST_REGISTRY="$(mktemp /tmp/raid10-registry.XXXXXX)"
}

# raid10_load_registry -- read the registry side file and populate
# RAID10_TEST_LOOPS / RAID10_TEST_FILES in the current shell.
raid10_load_registry() {
	[ -n "${RAID10_TEST_REGISTRY:-}" ] && [ -r "$RAID10_TEST_REGISTRY" ] || return 0
	local loop tmp
	while read -r loop tmp; do
		[ -n "$loop" ] && RAID10_TEST_LOOPS+=("$loop")
		[ -n "$tmp" ] && RAID10_TEST_FILES+=("$tmp")
	done < "$RAID10_TEST_REGISTRY"
}

# raid10_alloc_md -> echoes a free /dev/<prefix>N name in the 240..255
# range.  Stops anything left over from a previous failed run.
# For the ms variant a stale device node may exist but be empty; we
# accept it if array_state is "clear", matching llbitmap_alloc_ms_dev.
raid10_alloc_md() {
	local n
	for n in $(seq 240 255); do
		local dev="/dev/${RAID10_DEV_PREFIX}${n}"
		local name="${RAID10_DEV_PREFIX}${n}"
		if [ -b "$dev" ]; then
			"$MDADM" --stop "$dev" >/dev/null 2>&1 || true
			# After --stop the node may persist (ms variant); only
			# reuse it if there's no live array.
			local state
			state=$(cat "/sys/block/${name}/${RAID10_SYSFS_SUBDIR}/array_state" 2>/dev/null || echo "")
			case "$state" in
				clear|"") : ;;   # acceptable
				*)         continue ;;
			esac
		fi
		RAID10_TEST_MD="$name"
		echo "$dev"
		return 0
	done
	echo "FAIL: no free /dev/${RAID10_DEV_PREFIX} device in 240..255" >&2
	exit 1
}

# Sysfs base for an md/ms device (e.g. /sys/block/md240/md or .../ms).
_raid10_sysfs() {
	echo "/sys/block/$1/${RAID10_SYSFS_SUBDIR}"
}

# raid10_wait_idle MD_NAME [timeout_seconds]
raid10_wait_idle() {
	local md="$1" timeout="${2:-30}"
	local i
	for i in $(seq 1 $((timeout * 2))); do
		[ "$(cat "$(_raid10_sysfs "$md")/sync_action" 2>/dev/null)" = "idle" ] && return 0
		sleep 0.5
	done
	echo "FAIL: ${md} sync_action never went idle" >&2
	cat "$RAID10_MDSTAT" >&2
	return 1
}

# raid10_set_sync_speed MD_NAME KBPS  -- pin min and max to the same value.
raid10_set_sync_speed() {
	local md="$1" kbps="$2"
	echo "$kbps" > "$(_raid10_sysfs "$md")/sync_speed_max"
	echo "$kbps" > "$(_raid10_sysfs "$md")/sync_speed_min"
}

# raid10_start_check MD_NAME -- start a 'check' resync.
raid10_start_check() {
	echo check > "$(_raid10_sysfs "$1")/sync_action"
}

# raid10_stop_sync MD_NAME -- best-effort.
raid10_stop_sync() {
	echo idle > "$(_raid10_sysfs "$1")/sync_action" 2>/dev/null || true
}

# raid10_fio_p99_iops DEV SECONDS NJOBS -- echoes "<iops> <p99_us>".
# Uses --ioengine=sync because the barrier slow path is per-task; many
# parallel sync writers maximise lock contention on the resync_lock
# seqlock.
# Returns non-zero (with a message on stderr) if fio fails, its output
# does not parse, or the result is zero -- a zero baseline means the
# run measured nothing and must not feed the PASS/FAIL ratio.
raid10_fio_p99_iops() {
	local dev="$1" secs="$2" njobs="$3"
	local out line rc=0
	out=$(mktemp)
	fio --name=t --filename="$dev" --rw=randwrite --bs=4k \
	    --ioengine=sync --numjobs="$njobs" --time_based \
	    --runtime="$secs" --direct=1 --group_reporting \
	    --output-format=json --output="$out" >/dev/null 2>&1 || rc=$?
	if [ "$rc" -ne 0 ]; then
		echo "ERROR: fio failed on $dev (exit $rc)" >&2
		rm -f "$out"
		return 1
	fi
	line=$(python3 -c "
import json, sys
d = json.load(open('$out'))
w = d['jobs'][0]['write']
iops = int(w['iops'])
p99_us = w['clat_ns']['percentile']['99.000000'] / 1000.0
if iops <= 0 or p99_us <= 0:
    sys.exit(f'zero fio result: iops={iops} p99_us={p99_us}')
print(f'{iops} {p99_us:.0f}')
") || rc=$?
	rm -f "$out"
	if [ "$rc" -ne 0 ]; then
		echo "ERROR: could not extract iops/p99 from fio output on $dev" >&2
		return 1
	fi
	echo "$line"
}

# raid10_assert_syncing MD_NAME WHEN -- return non-zero unless a sync
# action is currently running; WHEN labels the error message.
raid10_assert_syncing() {
	local md="$1" when="$2" action
	action=$(cat "$(_raid10_sysfs "$md")/sync_action" 2>/dev/null || echo unreadable)
	case "$action" in
		check|repair|resync|recover) return 0 ;;
	esac
	echo "ERROR: expected an active sync $when, sync_action=$action" >&2
	return 1
}

raid10_cleanup() {
	set +e
	# Pick up anything created in subshells.
	raid10_load_registry
	if [ -n "$RAID10_TEST_MD" ] && [ -b "/dev/${RAID10_TEST_MD}" ]; then
		raid10_stop_sync "$RAID10_TEST_MD"
		"$MDADM" --stop "/dev/${RAID10_TEST_MD}" >/dev/null 2>&1
	fi
	udevadm settle >/dev/null 2>&1
	local loop f
	for loop in "${RAID10_TEST_LOOPS[@]:-}"; do
		losetup -d "$loop" >/dev/null 2>&1
	done
	for f in "${RAID10_TEST_FILES[@]:-}"; do
		rm -f "$f"
	done
	[ -n "${RAID10_TEST_REGISTRY:-}" ] && rm -f "$RAID10_TEST_REGISTRY"
	set -e
}

trap raid10_cleanup EXIT

raid10_pass() { echo "PASS: $1"; exit 0; }
raid10_fail() { echo "FAIL: $1" >&2; exit 1; }
raid10_skip() { echo "SKIP: $1" >&2; exit 4; }
