# SPDX-License-Identifier: GPL-2.0
# shellcheck shell=bash
# Shared helpers for the md latency-aware read-balance selftests.
# Sourced by latency-balance-*.sh; never run directly.
#
# These tests exercise the shortest-expected-delay (SED) read balancer
# in drivers/md/{raid1,raid10}.c.  They build an md array on top of two
# (or more) dm-delay legs so per-leg read latency can be skewed on
# demand, then assert that traffic follows the faster leg, migrates
# when the skew is swapped, spreads under real queuing, and falls back
# to the stock policy when the feature is off.
#
# By default the tests target the meshstor-ms variant (MD_SUBSYS=ms) via
# /dev/msN on a kernel with raid1_ms.ko / raid10_ms.ko loaded, which only
# carry the SED code on a kernel built from this tree -- on any other kernel
# the feature-detect check skips them.  Override with MD_SUBSYS=md to target
# the in-tree md driver instead.  Individual knobs (MDADM, LATBAL_*) override
# the per-subsystem defaults when set explicitly, e.g.:
#
#   MD_SUBSYS=ms                     # meshstor-ms (default); or 'md' for in-tree
#   MDADM=/home/mykola/mdadm/mdadm   # mdadm that understands --subsys=ms
#   LATBAL_SUBSYS=ms                 # pass --subsys=ms to mdadm (default none)
#   LATBAL_DEV_PREFIX=ms             # device basename prefix (default md)
#   LATBAL_SYSFS_SUBDIR=ms           # /sys/block/<dev>/<subdir> (default md)
#   LATBAL_MDSTAT=/proc/msstat       # personality file (default /proc/mdstat)
#
# Loop devices over a tmpfs scratch dir back each dm-delay leg, so the
# only latency in the stack is the one dm-delay injects -- exactly what
# the EWMA must learn.

set -u

# MD_SUBSYS selects the subsystem and derives the device/sysfs/stat knobs
# AND the default mdadm, matching the raid10/ and takeover/ suites so a
# single MD_SUBSYS=ms drives the whole composed md selftest tree (and so a
# standalone `MD_SUBSYS=ms bash latency-balance-raid1.sh` "just works" like
# its siblings, not just under the orchestrator). Each LATBAL_* and MDADM
# still overrides when set explicitly.
#   ms (default) -> meshstor-ms (raid1_ms/raid10_ms under ms_mod.ko, major
#                   252, /dev/msN, /sys/block/msN/ms, /proc/msstat, patched
#                   mdadm with --subsys=ms).
#   md           -> in-tree md driver (stock /dev/mdN, /proc/mdstat, system mdadm).
MD_SUBSYS="${MD_SUBSYS:-ms}"
case "$MD_SUBSYS" in
ms)
	MDADM="${MDADM:-/home/mykola/mdadm/mdadm}"
	LATBAL_SUBSYS="${LATBAL_SUBSYS:-ms}"
	LATBAL_DEV_PREFIX="${LATBAL_DEV_PREFIX:-ms}"
	LATBAL_SYSFS_SUBDIR="${LATBAL_SYSFS_SUBDIR:-ms}"
	LATBAL_MDSTAT="${LATBAL_MDSTAT:-/proc/msstat}"
	;;
md)
	MDADM="${MDADM:-mdadm}"
	LATBAL_SUBSYS="${LATBAL_SUBSYS:-}"
	LATBAL_DEV_PREFIX="${LATBAL_DEV_PREFIX:-md}"
	LATBAL_SYSFS_SUBDIR="${LATBAL_SYSFS_SUBDIR:-md}"
	LATBAL_MDSTAT="${LATBAL_MDSTAT:-/proc/mdstat}"
	;;
*)
	echo "FAIL: unknown MD_SUBSYS=$MD_SUBSYS (want 'ms' or 'md')" >&2
	exit 1
	;;
esac
LATBAL_IMG_DIR="${LATBAL_IMG_DIR:-/dev/shm}"
# Per-leg base image size.  The array data area is a touch smaller.
LATBAL_LEG_MB="${LATBAL_LEG_MB:-256}"
# Default "slow" dm-delay value, milliseconds.
LATBAL_SLOW_MS="${LATBAL_SLOW_MS:-2}"

# Bookkeeping for cleanup.  Index i of each array describes leg i.
LATBAL_LOOPS=()		# /dev/loopN backing devices
LATBAL_IMAGES=()	# scratch image files
LATBAL_DMNAMES=()	# dm-delay target names (dmsetup)
LATBAL_MD=""		# md device basename, e.g. md240
LATBAL_DEV=""		# full md device path, e.g. /dev/md240
LATBAL_SYS=""		# /sys/block/<md>/<subdir>
# Unique-per-run dm name prefix so parallel/leftover runs do not clash.
LATBAL_TAG="latbal-$$"

latbal_pass() { echo "PASS: $1"; exit 0; }
latbal_fail() { echo "FAIL: $1" >&2; exit 1; }
latbal_skip() { echo "SKIP: $1" >&2; exit 4; }
latbal_log()  { echo "$1"; }

# latbal_mdadm ARGS... -- mdadm with the subsystem selector baked in.
latbal_mdadm() {
	if [ -n "$LATBAL_SUBSYS" ]; then
		"$MDADM" --subsys="$LATBAL_SUBSYS" "$@"
	else
		"$MDADM" "$@"
	fi
}

latbal_require_root() {
	if [ "$(id -u)" -ne 0 ]; then
		latbal_skip "must run as root (try: sudo $0)"
	fi
}

latbal_require_tools() {
	local tool
	for tool in losetup dmsetup fio blockdev awk; do
		if ! command -v "$tool" >/dev/null 2>&1; then
			latbal_skip "missing tool: $tool"
		fi
	done
	if ! command -v "$MDADM" >/dev/null 2>&1 && ! [ -x "$MDADM" ]; then
		latbal_skip "missing mdadm at: $MDADM"
	fi
}

# Personality file first line: "Personalities : [raid1] [raid10]".
latbal_require_personality() {	# $1 = raid1|raid10
	if ! head -1 "$LATBAL_MDSTAT" 2>/dev/null | grep -qw "$1"; then
		latbal_skip "$1 personality not registered in $LATBAL_MDSTAT"
	fi
}

latbal_require_dm_delay() {
	modprobe dm-delay >/dev/null 2>&1 || true
	if ! dmsetup targets 2>/dev/null | grep -qw delay; then
		latbal_skip "dm-delay target unavailable"
	fi
}

latbal_require_tmpfs() {
	local fs
	fs=$(stat -f -c '%T' "$LATBAL_IMG_DIR" 2>/dev/null || echo unknown)
	case "$fs" in
		tmpfs|ramfs) : ;;
		*) latbal_skip "$LATBAL_IMG_DIR is not tmpfs/ramfs (got $fs) -- backing store too slow to measure us-scale latency" ;;
	esac
}

# latbal_sysfs MD_NAME -> /sys/block/<name>/<subdir>
latbal_sysfs() { echo "/sys/block/$1/$LATBAL_SYSFS_SUBDIR"; }

# latbal_make_leg IDX -- create loop-backed dm-delay leg IDX with 0ms
# delay.  Runs in the current shell (not $(...)) so it can append to the
# bookkeeping arrays.
latbal_make_leg() {
	local idx="$1"
	local img loop sectors name
	img="$(mktemp "${LATBAL_IMG_DIR}/${LATBAL_TAG}-${idx}.XXXXXX.img")"
	truncate -s "${LATBAL_LEG_MB}M" "$img"
	loop="$(losetup -f --show "$img")"
	LATBAL_IMAGES+=("$img")
	LATBAL_LOOPS+=("$loop")
	sectors="$(blockdev --getsz "$loop")"
	name="${LATBAL_TAG}-${idx}"
	dmsetup create "$name" --table "0 $sectors delay $loop 0 0"
	LATBAL_DMNAMES+=("$name")
}

# latbal_leg_path IDX -> /dev/mapper/<dmname>
latbal_leg_path() { echo "/dev/mapper/${LATBAL_DMNAMES[$1]}"; }

# latbal_set_delay IDX MS -- live-reload leg IDX's dm-delay to MS ms.
latbal_set_delay() {
	local idx="$1" ms="$2"
	local loop="${LATBAL_LOOPS[$idx]}" name="${LATBAL_DMNAMES[$idx]}"
	local sectors
	sectors="$(blockdev --getsz "$loop")"
	dmsetup suspend "$name"
	dmsetup reload "$name" --table "0 $sectors delay $loop 0 $ms"
	dmsetup resume "$name"
}

# latbal_reads_of IDX -- completed reads issued to leg IDX (diskstats f4).
latbal_reads_of() {
	local name="${LATBAL_DMNAMES[$1]}" dm
	dm=$(dmsetup info -c --noheadings -o blkdevname "$name")
	awk -v d="$dm" '$3==d {print $4}' /proc/diskstats
}

# latbal_alloc_md -- pick a free /dev/<prefix>N, set LATBAL_MD and
# LATBAL_DEV directly (NOT via echo + $(): a subshell could not export
# the globals).  Mirrors raid10_alloc_md: reuse a stale-but-clear node.
latbal_alloc_md() {
	local n dev name state
	for n in $(seq 240 255); do
		dev="/dev/${LATBAL_DEV_PREFIX}${n}"
		name="${LATBAL_DEV_PREFIX}${n}"
		if [ -b "$dev" ]; then
			latbal_mdadm --stop "$dev" >/dev/null 2>&1 || true
			state=$(cat "/sys/block/${name}/${LATBAL_SYSFS_SUBDIR}/array_state" 2>/dev/null || echo "")
			case "$state" in
				clear|"") : ;;
				*) continue ;;
			esac
		fi
		LATBAL_MD="$name"
		LATBAL_DEV="$dev"
		return 0
	done
	latbal_fail "no free /dev/${LATBAL_DEV_PREFIX} device in 240..255"
}

# latbal_create_array LEVEL NDEVS [LAYOUT] -- build the array over the
# already-created legs and wait for it to go idle.  Sets LATBAL_DEV /
# LATBAL_MD / LATBAL_SYS.
latbal_create_array() {
	local level="$1" ndevs="$2" layout="${3:-}"
	local i args
	latbal_alloc_md
	# One never-empty argv: avoids "${arr[@]}" on an empty array, which
	# trips set -u on bash < 4.4.
	args=(--create "$LATBAL_DEV" --run --force --level="$level"
	      --raid-devices="$ndevs" --assume-clean --metadata=1.2)
	[ -n "$layout" ] && args+=(--layout="$layout")
	for i in $(seq 0 $((ndevs - 1))); do
		args+=("$(latbal_leg_path "$i")")
	done
	udevadm settle >/dev/null 2>&1 || true
	echo y | latbal_mdadm "${args[@]}" >/dev/null 2>&1 \
		|| latbal_fail "mdadm --create level=$level failed"
	LATBAL_SYS="$(latbal_sysfs "$LATBAL_MD")"
	[ -d "$LATBAL_SYS" ] || latbal_fail "$LATBAL_SYS missing after create"
	latbal_wait_idle 60
}

# latbal_require_feature -- SKIP unless this kernel carries the SED
# read-balance knobs (i.e. it was built from this tree).
latbal_require_feature() {
	if [ ! -e "$LATBAL_SYS/latency_balance" ]; then
		latbal_skip "kernel lacks latency_balance knob (not built from this tree?)"
	fi
}

latbal_wait_idle() {	# [timeout_s]
	local timeout="${1:-60}" i action
	latbal_mdadm --wait "$LATBAL_DEV" >/dev/null 2>&1 || true
	for i in $(seq 1 $((timeout * 2))); do
		action="$(cat "$LATBAL_SYS/sync_action" 2>/dev/null || echo idle)"
		[ "$action" = "idle" ] && return 0
		sleep 0.5
	done
	latbal_fail "$LATBAL_MD sync_action never went idle (last: $action)"
}

# latbal_ewma_min / _max -- lowest/highest per-leg latency_ewma_ns.
# The array's component rdev dirs are dev-dm-* (legs are dm-delay).
latbal_ewma_min() { cat "$LATBAL_SYS"/dev-dm-*/latency_ewma_ns | sort -n | head -1; }
latbal_ewma_max() { cat "$LATBAL_SYS"/dev-dm-*/latency_ewma_ns | sort -n | tail -1; }

# latbal_run_fio SECONDS -- saturating 8k random read, deep queue.
latbal_run_fio() {
	fio --name=lat --filename="$LATBAL_DEV" --rw=randread --bs=8k \
	    --runtime="$1" --time_based --direct=1 --iodepth=16 \
	    --numjobs=4 --group_reporting --minimal >/dev/null
}

# latbal_run_fio_lowiops SECONDS -- ~50 IOPS QD1 trickle.
latbal_run_fio_lowiops() {
	fio --name=lat-trickle --filename="$LATBAL_DEV" --rw=randread --bs=8k \
	    --runtime="$1" --time_based --direct=1 --iodepth=1 \
	    --rate_iops=50 --minimal >/dev/null
}

# latbal_warm -- fill so reads span the device, then settle.
latbal_warm() {
	fio --name=warm --filename="$LATBAL_DEV" --rw=write --bs=1M \
	    --size=$((LATBAL_LEG_MB - 8))M --direct=1 --iodepth=8 >/dev/null
	latbal_run_fio 5
}

# latbal_share_check PHASE WANT PCT -- run 10s of fio, then assert the
# per-leg read share.  WANT is leg<N> (that leg >= PCT%) or "both"
# (every leg >= PCT%).
latbal_share_check() {
	local phase="$1" want="$2" pct="$3"
	local nlegs="${#LATBAL_DMNAMES[@]}" i tot=0
	local before=() after=() delta=()
	for i in $(seq 0 $((nlegs - 1))); do before[i]=$(latbal_reads_of "$i"); done
	latbal_run_fio 10
	local msg="$phase:"
	for i in $(seq 0 $((nlegs - 1))); do
		after[i]=$(latbal_reads_of "$i")
		delta[i]=$(( after[i] - before[i] ))
		tot=$(( tot + delta[i] ))
		msg="$msg leg$i=${delta[i]}"
	done
	echo "$msg"
	[ "$tot" -gt 0 ] || latbal_fail "$phase: no reads observed"
	case "$want" in
	leg*)
		local n="${want#leg}"
		[ $(( delta[n] * 100 )) -ge $(( tot * pct )) ] \
			|| latbal_fail "$phase: $want share < ${pct}%"
		;;
	both)
		for i in $(seq 0 $((nlegs - 1))); do
			[ $(( delta[i] * 100 )) -ge $(( tot * pct )) ] \
				|| latbal_fail "$phase: leg$i spread < ${pct}%"
		done
		;;
	esac
}

# --- dmesg splat capture (used by the stress test) ---------------------
# /dev/kmsg marker beats `dmesg -c`: it does not perturb the ring for
# anything else watching it, and survives ring wrap detection.
latbal_dmesg_mark() {
	LATBAL_DMESG_MARK="latbal-mark-$$-$1"
	echo "$LATBAL_DMESG_MARK" > /dev/kmsg 2>/dev/null || true
}

# latbal_dmesg_since_mark -> prints ring contents after the last mark.
latbal_dmesg_since_mark() {
	dmesg 2>/dev/null | awk -v m="${LATBAL_DMESG_MARK:-}" \
		'f{print} index($0,m){f=1}'
}

latbal_kasan_active() {
	{ zcat /proc/config.gz 2>/dev/null || cat "/boot/config-$(uname -r)" 2>/dev/null; } \
		| grep -q '^CONFIG_KASAN=y' && return 0
	dmesg 2>/dev/null | grep -qi 'kasan' && return 0
	return 1
}

latbal_cleanup() {
	set +e
	if [ -n "$LATBAL_DEV" ] && [ -b "$LATBAL_DEV" ]; then
		latbal_mdadm --stop "$LATBAL_DEV" >/dev/null 2>&1
	fi
	# Any extra arrays a test built and named itself.
	local extra
	for extra in ${LATBAL_EXTRA_MD:-}; do
		latbal_mdadm --stop "/dev/$extra" >/dev/null 2>&1
	done
	udevadm settle >/dev/null 2>&1
	local name loop img
	for name in "${LATBAL_DMNAMES[@]:-}"; do
		[ -n "$name" ] && dmsetup remove "$name" >/dev/null 2>&1
	done
	for loop in "${LATBAL_LOOPS[@]:-}"; do
		[ -n "$loop" ] && losetup -d "$loop" >/dev/null 2>&1
	done
	for img in "${LATBAL_IMAGES[@]:-}"; do
		[ -n "$img" ] && rm -f "$img"
	done
	set -e
}

trap latbal_cleanup EXIT
