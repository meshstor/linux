#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
#
# RED test for the per-bucket barrier conversion in drivers/md/raid10.c.
#
# Before "md/raid10: convert global barrier to per-bucket arrays":
#   struct r10conf {
#       atomic_t  nr_pending;       /* single scalar */
#       int       nr_waiting;       /* single scalar */
#       int       nr_queued;        /* single scalar */
#       int       barrier;          /* single scalar */
#       ...
#   }
# Any background resync sets barrier > 0, forcing *every* normal I/O
# (anywhere on the array) onto the wait_barrier() slow path.  The slow
# path takes write_seqlock_irq(&conf->resync_lock) -- a single
# system-wide spinlock -- around an nr_pending bump.  Under parallel
# writers the contention bumps the P99 latency of submission while
# resync is active.
#
# After the conversion, nr_pending/nr_waiting/barrier become per-bucket
# arrays (BARRIER_BUCKETS_NR ~= 1024 buckets of 64 MB each), and the
# fast-path wait_barrier_nolock() check looks at barrier[idx] for the
# request's own bucket.  Random I/O hitting a bucket where resync is
# not currently active stays on the fast path, so resync-induced P99
# inflation should disappear.
#
# What this test does:
#   1. Build a 4 x 2 GB tmpfs-backed RAID 10 (--assume-clean: skip the
#      initial mirror sync).
#   2. Pin sync_speed to a low rate so a 'check' stays running for the
#      whole measurement window.
#   3. Run a 4 KB random-write workload with many sync writers (default
#      256), once with the array idle and once with 'check' running.
#   4. Repeat for several trials and compare median P99 latency.
#
# Expected results on the pre-conversion (master) raid10:
#   ratio_p99 >= 1.10 -- contention on the global seqlock is observable
#   even on fast hardware/tmpfs.  On slower disks or busier systems the
#   gap is larger.
#
# Expected results on the per-bucket raid10:
#   ratio_p99 <  1.10 -- random writes mostly skip the slow path.
#
# Override with RAID10_P99_RATIO_THRESHOLD to retune for your hardware
# (e.g. RAID10_P99_RATIO_THRESHOLD=1.05).  Override RAID10_TRIALS,
# RAID10_NJOBS, RAID10_FIO_SECS, RAID10_SYNC_KBPS as needed.

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
. "${HERE}/lib.sh"

THRESHOLD="${RAID10_P99_RATIO_THRESHOLD:-1.10}"
TRIALS="${RAID10_TRIALS:-3}"
NJOBS="${RAID10_NJOBS:-256}"
FIO_SECS="${RAID10_FIO_SECS:-8}"
SYNC_KBPS="${RAID10_SYNC_KBPS:-8192}"
IMG_DIR="${RAID10_IMG_DIR:-/dev/shm}"
LOOP_SIZE="${RAID10_LOOP_SIZE:-2G}"

raid10_require_root
raid10_require_tools
raid10_require_module
# 4 loop images plus 1 GB slack for fio/json scratch.
raid10_require_tmpfs "$IMG_DIR" \
	"$((4 * $(raid10_size_to_kb "$LOOP_SIZE") + 1024 * 1024))"

# Command substitution runs in a subshell, so RAID10_TEST_MD set inside
# raid10_alloc_md is lost.  Extract the basename from the path and also
# set the trap-side global so cleanup works.
DEV="$(raid10_alloc_md)"
MD="${DEV##*/}"
RAID10_TEST_MD="$MD"

# Same reason -- raid10_make_loop records its created loops/files into a
# side file we read back here so cleanup can tear them down.
raid10_init_registry
LOOPS=()
for i in 0 1 2 3; do
	LOOPS+=("$(raid10_make_loop "$IMG_DIR" "$LOOP_SIZE")")
done
raid10_load_registry

"$MDADM" --create --run --force --assume-clean "$DEV" --level=10 \
	--raid-devices=4 --layout=n2 "${LOOPS[@]}" >/dev/null 2>&1
sleep 1
raid10_wait_idle "$MD"

raid10_set_sync_speed "$MD" "$SYNC_KBPS"

# Collect P99 latency for one (idle, resync) trial pair.
# Echoes "<idle_iops> <idle_p99_us> <resync_iops> <resync_p99_us>".
# Returns non-zero if a fio leg fails, the 'check' is not running for
# the whole resync measurement window, or the array never returns to
# idle between legs (a still-syncing "idle" leg inflates the baseline
# and deflates the ratio, silently masking a real regression).
# NB: trial is invoked from a `|| ` list, so `set -e` is suppressed in
# its body -- every command that can fail needs an explicit
# `|| return 1`.
trial() {
	raid10_wait_idle "$MD" || return 1
	local idle_line
	idle_line="$(raid10_fio_p99_iops "$DEV" "$FIO_SECS" "$NJOBS")" || return 1
	raid10_wait_idle "$MD" || return 1

	raid10_start_check "$MD"
	# Give kernel a moment to actually start the resync thread.
	sleep 1
	raid10_assert_syncing "$MD" "at start of the resync fio window" || return 1
	local resync_line
	resync_line="$(raid10_fio_p99_iops "$DEV" "$FIO_SECS" "$NJOBS")" || return 1
	raid10_assert_syncing "$MD" "at end of the resync fio window" || return 1
	raid10_stop_sync "$MD"
	raid10_wait_idle "$MD" || return 1

	echo "$idle_line $resync_line"
}

# Run trials and accumulate.
declare -a IDLE_IOPS IDLE_P99 RESYNC_IOPS RESYNC_P99
for t in $(seq 1 "$TRIALS"); do
	line="$(trial)" || raid10_fail "trial $t failed (see errors above)"
	read -r ii ip ri rp <<< "$line"
	[ -n "${rp:-}" ] || raid10_fail "trial $t returned incomplete data: '$line'"
	IDLE_IOPS+=("$ii"); IDLE_P99+=("$ip")
	RESYNC_IOPS+=("$ri"); RESYNC_P99+=("$rp")
	printf 'trial %d: idle iops=%7d p99=%5dus  |  resync iops=%7d p99=%5dus  |  p99 ratio=%.2fx\n' \
		"$t" "$ii" "$ip" "$ri" "$rp" \
		"$(python3 -c "print($rp/$ip if $ip else 0)")"
done

# Use the median ratio to suppress single-trial noise.
# Pass each array as space-separated args; python parses sys.argv.
RESULT="$(python3 -c '
import sys
n = (len(sys.argv) - 1) // 2
idle   = sorted(int(x) for x in sys.argv[1:1+n])
resync = sorted(int(x) for x in sys.argv[1+n:])
mid = n // 2
if idle[mid] <= 0:
    sys.exit("idle p99 median is zero -- no valid baseline")
ratio = resync[mid] / idle[mid]
print(f"{ratio:.3f}")
' "${IDLE_P99[@]}" "${RESYNC_P99[@]}")" || raid10_fail "ratio computation failed"

echo
echo "median p99 ratio (during-resync / idle) = ${RESULT}x"
echo "threshold                                = ${THRESHOLD}x"

# Compare ratio to threshold with python (avoid bc dependency).
PASS=$(python3 -c "print(1 if float('$RESULT') < float('$THRESHOLD') else 0)")
if [ "$PASS" = "1" ]; then
	raid10_pass "p99 ratio ${RESULT}x < ${THRESHOLD}x (per-bucket barriers in effect)"
else
	raid10_fail "p99 ratio ${RESULT}x >= ${THRESHOLD}x (global-barrier contention observed during resync)"
fi
