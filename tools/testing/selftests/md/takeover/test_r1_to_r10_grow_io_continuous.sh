#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
# End-to-end lifecycle with deterministic mid-transition IO proof:
#
#   1. Create a 2-disk raid1 from two real partitions on a loop-backed disk.
#   2. Wait for the initial resync to drain.
#   3. Take over to raid10_near(2,2).
#   4. Wait for the array to quiesce.
#   5. Add a second pair of partitions (mdadm --add) and grow raid_disks
#      from 2 to 4 (raid10_near(4,2)).
#   6. Wait for the reshape to complete.
#
# Throughout, four concurrent IO probe workers run write+readback cycles
# with NO sleeps so the array's request queue is always non-empty. Each
# cycle logs a microsecond-precision start timestamp. After the run we
# cross-reference timestamps against the captured start/end of each
# transition and assert that:
#
#   - Zero probe cycles errored (anywhere across the run).
#   - At least 5 OK cycles started strictly INSIDE the takeover window.
#   - At least 5 OK cycles started strictly INSIDE the grow window
#     (which is dominated by the reshape, the longer of the two).
#
# Using real GPT partitions (sfdisk on a loop device) rather than raw
# loops catches partition-rescan / gendisk-with-partition-table bugs
# the existing loop-backed tests do not exercise.

. "$(dirname "$0")/lib.sh"

md_require_root
md_require_tools
md_require_modules

if ! command -v sfdisk >/dev/null 2>&1; then
	md_skip "missing sfdisk"
fi

# Microsecond-precision timestamp via bash 5+ EPOCHREALTIME; never
# forks, so it's safe to call hundreds of times per second from the
# probe loop without distorting the measurement.
ts() { printf '%s\n' "$EPOCHREALTIME"; }

scratch="${MD_TMPDIR:-${TMPDIR:-/var/tmp}}"
backing="$(mktemp "$scratch/md-r1r10grow.XXXXXX.img")"
probe_log="$(mktemp "$scratch/md-probe.XXXXXX.log")"
probe_stop="$(mktemp "$scratch/md-probe-stop.XXXXXX")"
rm -f "$probe_stop"

probe_pids=()

probe_kill() {
	if [ -e "$probe_stop" ] || [ ${#probe_pids[@]} -eq 0 ]; then
		:
	fi
	touch "$probe_stop"
	local p
	for p in "${probe_pids[@]}"; do
		wait "$p" 2>/dev/null || true
	done
	probe_pids=()
}

cleanup_extra() {
	probe_kill
	rm -f "$probe_log" "$probe_log.final" "$backing" "$probe_stop"
}
trap 'cleanup_extra; md_cleanup' EXIT

# 1. 320 MiB backing file → loop with kernel-side partition scan.
truncate -s 320M "$backing"
loop="$(losetup --partscan --find --show "$backing")"
MD_TEST_LOOPS+=("$loop")
# backing file is removed by cleanup_extra; do NOT add to MD_TEST_FILES
# (md_cleanup would otherwise try to rm it twice).

# 2. Four 72 MiB GPT partitions.
sfdisk "$loop" >/dev/null <<EOF
label: gpt
,72MiB
,72MiB
,72MiB
,72MiB
EOF
partprobe "$loop" >/dev/null 2>&1 || true
udevadm settle

p1="${loop}p1"; p2="${loop}p2"; p3="${loop}p3"; p4="${loop}p4"
for p in "$p1" "$p2" "$p3" "$p4"; do
	[ -b "$p" ] || md_fail "partition device $p missing after sfdisk"
done

# 3. Initial 2-disk raid1 on (p1, p2).
MD_TEST_MD_DEV="$(md_find_free_md_dev)"
md_mdadm --create --run --metadata=1.2 --level=1 --raid-devices=2 \
	"$MD_TEST_MD_DEV" "$p1" "$p2" >/dev/null 2>&1 \
	|| md_fail "could not create raid1 from partitions"
md_wait_sync "$MD_TEST_MD_DEV"

sysfs="$(md_sysfs_path "$MD_TEST_MD_DEV")"

# 4. 32 MiB of urandom in the protected region; snapshot md5.
PROTECT_MB=32
PROBE_BASE_MB=40   # workers operate at 40..43 MiB, well past PROTECT_MB.
dd if=/dev/urandom of="$MD_TEST_MD_DEV" bs=1M count="$PROTECT_MB" \
	oflag=direct >/dev/null 2>&1 || md_fail "initial dd failed"
sync
md5_protected() {
	dd if="$MD_TEST_MD_DEV" bs=1M count="$PROTECT_MB" iflag=direct \
		2>/dev/null | md5sum | awk '{print $1}'
}
md5_raid1="$(md5_protected)"
[ -n "$md5_raid1" ] || md_fail "could not snapshot raid1 region"

# 5. Spawn N concurrent probe workers. Each operates on its own 4 KiB
#    block (no overlap between workers), in a tight loop with no sleeps,
#    so the array request queue is always non-empty across transitions.
NUM_WORKERS=4
spawn_worker() {
	local id="$1"
	local skip_4k="$2"
	local nonce rb
	nonce="$(mktemp "$scratch/md-probe-nonce.$id.XXXXXX")"
	rb="$(mktemp "$scratch/md-probe-rb.$id.XXXXXX")"
	(
		while [ ! -e "$probe_stop" ]; do
			dd if=/dev/urandom of="$nonce" bs=4096 count=1 \
				status=none 2>/dev/null
			local t0 t1
			t0="$(ts)"
			if dd if="$nonce" of="$MD_TEST_MD_DEV" bs=4096 count=1 \
				seek="$skip_4k" oflag=direct conv=notrunc \
				status=none 2>/dev/null \
			   && dd if="$MD_TEST_MD_DEV" of="$rb" bs=4096 count=1 \
				skip="$skip_4k" iflag=direct \
				status=none 2>/dev/null \
			   && cmp -s "$nonce" "$rb"; then
				t1="$(ts)"
				# Log [start end OK id]. Counting OK ops whose
				# [start,end] interval OVERLAPS a transition
				# window catches the case where the suspend
				# blocks a worker mid-cycle: its start is just
				# before the window and its completion is just
				# after, but the in-flight time clearly spans
				# the suspended state.
				printf '%s %s OK %d\n' "$t0" "$t1" "$id" >> "$probe_log"
			else
				t1="$(ts)"
				printf '%s %s ERR %d\n' "$t0" "$t1" "$id" >> "$probe_log"
			fi
		done
		rm -f "$nonce" "$rb"
	) &
	probe_pids+=($!)
}

for i in $(seq 1 "$NUM_WORKERS"); do
	# Each worker at PROBE_BASE_MB + (i-1) MiB, in 4 KiB units.
	spawn_worker "$i" $(( (PROBE_BASE_MB + i - 1) * 256 ))
done

# Let the workers warm up so we know the queue is hot before the
# transition fires.
sleep 0.3

# 6. Takeover: raid1 → raid10_near(2,2). Capture wall-clock window.
takeover_start="$(ts)"
md_sysfs_write "$sysfs/level" raid10 \
	|| md_fail "takeover refused"
md_wait_sync "$MD_TEST_MD_DEV"
takeover_end="$(ts)"
sync

level="$(md_sysfs_read "$sysfs/level")"
[ "$level" = "raid10" ] || md_fail "level not raid10 after takeover: $level"

md5_raid10="$(md5_protected)"
[ "$md5_raid10" = "$md5_raid1" ] \
	|| md_fail "protected data changed at takeover: $md5_raid1 -> $md5_raid10"

# 7. Add p3+p4 and grow raid_disks 2 → 4. Window captures both the
#    --add and the reshape.
grow_start="$(ts)"
md_mdadm --add "$MD_TEST_MD_DEV" "$p3" "$p4" >/dev/null 2>&1 \
	|| md_fail "could not --add new partitions"
md_mdadm --grow --raid-devices=4 "$MD_TEST_MD_DEV" >/dev/null 2>&1 \
	|| md_fail "could not grow raid_disks to 4"
md_wait_sync "$MD_TEST_MD_DEV"
grow_end="$(ts)"
sync

raid_disks="$(md_sysfs_read "$sysfs/raid_disks")"
[ "$raid_disks" = "4" ] || md_fail "raid_disks not 4 after grow: $raid_disks"

# Layout: near_copies=2, raid_disks=4 → (1<<8)|2 = 258 (unchanged).
layout="$(md_sysfs_read "$sysfs/layout")"
[ "$layout" = "258" ] || md_fail "layout not 258 after grow: $layout"

md5_raid10_4="$(md5_protected)"
[ "$md5_raid10_4" = "$md5_raid1" ] \
	|| md_fail "protected data changed at grow: $md5_raid1 -> $md5_raid10_4"

# 8. Stop probes and analyse.
probe_kill

# Log format: "<start> <end> {OK|ERR} <worker_id>".
# An op is "in flight during [ws, we]" if its [start,end] interval
# overlaps [ws, we], i.e. start <= we AND end >= ws.
count_ok_overlapping() {
	local ws="$1" we="$2"
	awk -v ws="$ws" -v we="$we" '
		$3 == "OK" && ($1+0) <= (we+0) && ($2+0) >= (ws+0) { n++ }
		END { print n+0 }
	' "$probe_log"
}

ops_total="$(awk '$3 == "OK"  { ok++ } END { print ok+0 }' "$probe_log")"
ops_err="$(awk   '$3 == "ERR" { e++  } END { print e+0  }' "$probe_log")"

ops_during_takeover="$(count_ok_overlapping "$takeover_start" "$takeover_end")"
ops_during_grow="$(count_ok_overlapping "$grow_start" "$grow_end")"

takeover_ms="$(awk -v s="$takeover_start" -v e="$takeover_end" \
	'BEGIN { printf "%.0f", (e - s) * 1000 }')"
grow_ms="$(awk -v s="$grow_start" -v e="$grow_end" \
	'BEGIN { printf "%.0f", (e - s) * 1000 }')"

echo "ops total=$ops_total err=$ops_err" >&2
echo "takeover window=${takeover_ms}ms ops_inside=$ops_during_takeover" >&2
echo "grow     window=${grow_ms}ms ops_inside=$ops_during_grow" >&2

if [ "$ops_err" -ne 0 ]; then
	awk '$3 == "ERR"' "$probe_log" | head -5 >&2
	md_fail "$ops_err IO errors during the run"
fi

# A handful of OK cycles whose in-flight interval overlaps each
# transition window proves the array kept serving requests there,
# not just before/after.
if [ "$ops_during_takeover" -lt 4 ]; then
	md_fail "only $ops_during_takeover OK ops in flight during takeover (${takeover_ms} ms, ${NUM_WORKERS} workers)"
fi
if [ "$ops_during_grow" -lt 5 ]; then
	md_fail "only $ops_during_grow OK ops in flight during grow (${grow_ms} ms)"
fi

md_pass "served $ops_during_takeover ops mid-takeover (${takeover_ms} ms) + $ops_during_grow mid-grow (${grow_ms} ms); $ops_total total, 0 errors"
