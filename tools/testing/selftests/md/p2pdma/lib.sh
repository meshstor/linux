# SPDX-License-Identifier: GPL-2.0
# Guest-side helpers for the p2pdma selftests. Sourced, never executed.
# Conventions match ../llbitmap/lib.sh: MD_SUBSYS=ms by default, exit 4 = SKIP.
#
# v6 semantics (see docs/superpowers/plans/2026-07-29-p2pdma-v6-rework.md):
# a leg that fails a write with BLK_STS_P2PDMA gets its range badblocked,
# is NOT faulted, does NOT get WantReplacement, and the master write
# SUCCEEDS off any surviving leg. Only when EVERY leg fails does the
# master write fail -- honestly (a real errno), never as a silent
# success. Ordinary (non-P2PDMA) statuses keep upstream's ordinary
# write-error handling (badblock + WantReplacement, possibly a fault).
set -u

MD_SUBSYS="${MD_SUBSYS:-ms}"
case "$MD_SUBSYS" in
ms) P2P_DEV_PREFIX="ms";  P2P_SYSFS="ms";  P2P_CORE_MOD="ms_mod"
    P2P_RAID1_MOD="raid1_ms"; P2P_RAID10_MOD="raid10_ms" ;;
md) P2P_DEV_PREFIX="md";  P2P_SYSFS="md";  P2P_CORE_MOD="md_mod"
    P2P_RAID1_MOD="raid1";    P2P_RAID10_MOD="raid10" ;;
*)  echo "FAIL: unknown MD_SUBSYS=$MD_SUBSYS" >&2; exit 1 ;;
esac

MDADM="${MDADM:-/usr/local/bin/mdadm}"
MS_MOD_DIR="${MS_MOD_DIR:-}"
MODULES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/modules"

# rdev_set_badblocks()'s entry table is one page of 64-bit (sector<<9|len)
# entries -- PAGE_SIZE/8 = 512 on a 4K-page host -- and each entry covers at
# most 512 sectors. Once the table is full, rdev_set_badblocks() itself
# calls md_error(), faulting the member. Tests key off this constant rather
# than a hard-coded 512 so the rationale travels with the number.
MAX_BADBLOCKS=512

p2p_pass() { echo "PASS: $*"; exit 0; }
p2p_fail() { echo "FAIL: $*" >&2; exit 1; }
p2p_skip() { echo "SKIP: $*" >&2; exit 4; }

p2p_require_root() { [ "$(id -u)" -eq 0 ] || p2p_skip "must run as root"; }

# Rig precondition. Every test calls this TWICE on purpose: once on the
# HOST, above its `exec run_vm.sh`, and once again inside the guest. The
# host-side call is what keeps a rigless box from booting one QEMU per test
# only to SKIP inside each -- wasted minutes, and one orphaned-QEMU risk per
# boot (see run_all.sh's timeout note). Both paths see the same filesystem,
# so the predicates give the same answer in either place.
p2p_require_rig() {
	[ -x "$MDADM" ] || p2p_skip "mdadm not found at $MDADM"
	[ -n "$MS_MOD_DIR" ] && [ -d "$MS_MOD_DIR" ] \
		|| p2p_skip "MS_MOD_DIR not set (directory with the built md modules)"
}

p2p_require_tool() {
	command -v "$1" >/dev/null 2>&1 || p2p_skip "missing tool: $1"
}

# dm_errstat is an out-of-tree dm target; a fresh VM has no dm_mod loaded
# yet (the host almost always does, which is how this dependency stayed
# invisible until the suite first ran). modprobe the dm core first, or
# every dm_* symbol in dm_errstat.ko resolves as unknown.
p2p_load_dm_errstat() {
	modprobe dm-mod 2>/dev/null || true
	insmod "$MODULES_DIR/dm_errstat.ko"
}

p2p_load_ms_modules() {
	insmod "$MS_MOD_DIR/$P2P_CORE_MOD.ko" 2>/dev/null || true
	insmod "$MS_MOD_DIR/$P2P_RAID1_MOD.ko" 2>/dev/null || true
	insmod "$MS_MOD_DIR/$P2P_RAID10_MOD.ko" 2>/dev/null || true
	grep -q "^$P2P_CORE_MOD " /proc/modules || p2p_fail "cannot load $P2P_CORE_MOD"
}

# p2p_wait_nvme_serial <serial> [seconds] -> rc 0 once the controller with
# that serial is visible in sysfs. NVMe probing is asynchronous; a test
# that reads /sys/class/nvme immediately after boot can race enumeration
# (only test_rig_cmb_provider.sh is fast enough to hit this -- every other
# test loads modules first, which gives probing time to finish).
p2p_wait_nvme_serial() {
	local want="$1" t="${2:-15}"
	while [ "$t" -gt 0 ]; do
		p2p_nvme_by_serial "$want" >/dev/null 2>&1 && return 0
		sleep 1
		t=$((t - 1))
	done
	return 1
}

# nvme device node by qemu serial (cmb0/leg1/leg2) -> /dev/nvmeXn1
p2p_nvme_by_serial() {
	local want="$1" c
	for c in /sys/class/nvme/nvme*; do
		[ "$(tr -d ' ' <"$c/serial")" = "$want" ] || continue
		echo "/dev/$(basename "$c")n1"; return 0
	done
	return 1
}

# PCI BDF of the nvme controller with the given serial (p2pmem provider)
p2p_bdf_by_serial() {
	local want="$1" c
	for c in /sys/class/nvme/nvme*; do
		[ "$(tr -d ' ' <"$c/serial")" = "$want" ] || continue
		basename "$(readlink -f "$c/device")"; return 0
	done
	return 1
}

P2P_ARRAY=""
p2p_make_array() {   # p2p_make_array <level> <dev1> <dev2> [dev3 dev4 ...] -> echoes /dev/ms0
	local level="$1" dev="/dev/${P2P_DEV_PREFIX}0"
	shift
	"$MDADM" --create "$dev" --run --force --level="$level" \
		--raid-devices=$# --assume-clean --bitmap=none \
		--metadata=1.2 "$@" >/dev/null 2>&1 \
		|| p2p_fail "mdadm --create $dev failed"
	P2P_ARRAY="$dev"
	echo "$dev"
}

p2p_cleanup() {
	[ -n "$P2P_ARRAY" ] && "$MDADM" --stop "$P2P_ARRAY" >/dev/null 2>&1
	rmmod md_p2p_test 2>/dev/null || true
	return 0
}

# errno of the last md_p2p_test run, from its dmesg result line:
#   md_p2p_test: result op=write target=/dev/ms0 sector=0 mixed=0 status=8 errno=-22
p2p_last_result() {
	dmesg | grep 'md_p2p_test: result' | tail -1 \
		| sed -n 's/.*errno=\(-\?[0-9]*\).*/\1/p'
}

p2p_last_status() {
	dmesg | grep 'md_p2p_test: result' | tail -1 \
		| sed -n 's/.*status=\([0-9]*\).*/\1/p'
}

# Submit one p2p I/O via the test module. Usage:
#   p2p_io <op> <target-dev> <provider-bdf> [extra insmod args...]
#   -> echoes errno (0 = success)
# Runs in command substitution, so on failure it returns 1 (never exits)
# and echoes nothing, printing a FAIL line to stderr instead.
p2p_io() {
	local op="$1" tgt="$2" prov="$3" before after
	shift 3
	[ -e "$MODULES_DIR/md_p2p_test.ko" ] || p2p_fail "md_p2p_test.ko not built (run make in modules/)"
	rmmod md_p2p_test 2>/dev/null || true
	before=$(dmesg | grep -c 'md_p2p_test: result' || true)
	insmod "$MODULES_DIR/md_p2p_test.ko" \
		provider="$prov" target="$tgt" op="$op" "$@" >/dev/null 2>&1 || true
	after=$(dmesg | grep -c 'md_p2p_test: result' || true)
	if [ "$after" -le "$before" ]; then
		echo "FAIL: p2p_io: no new result line (insmod failed before I/O?)" >&2
		return 1
	fi
	p2p_last_result
}

# p2p_mixed_bio_allowed <target-dev> <provider-bdf>
#   rc 0 -> this kernel puts a host page and a P2P page in the SAME bio
#           (6.12/6.14-class: the mixed-pgmap scenario is constructible)
#   rc 1 -> it refuses to (>= 6.17 bio_add_page() pgmap rule: the scenario
#           cannot be built at all, so nothing downstream can be exercised)
#   rc 2 -> indeterminate; the probe could not be trusted (treat as an error,
#           never as either answer)
#
# This is a POSITIVE probe, not an inference from a failed I/O. md_p2p_test's
# probe_mixed=1 runs host+host and dev+dev controls beside the host+dev case
# and reports all three, so an unrelated breakage in the module cannot read as
# "the kernel closed the hole" -- see md_p2p_probe_mixed()'s comment for why
# that distinction is the whole point. Submits no I/O and leaves nothing
# loaded.
p2p_mixed_bio_allowed() {
	local tgt="$1" prov="$2" line
	[ -e "$MODULES_DIR/md_p2p_test.ko" ] || return 2
	rmmod md_p2p_test 2>/dev/null || true
	insmod "$MODULES_DIR/md_p2p_test.ko" \
		provider="$prov" target="$tgt" probe_mixed=1 >/dev/null 2>&1 || true
	rmmod md_p2p_test 2>/dev/null || true
	line="$(dmesg | grep 'md_p2p_test: mixed_pgmap_probe' | tail -1)"
	case "$line" in
	*"host_pair=1 dev_pair=1 mixed=1"*) return 0 ;;
	*"host_pair=1 dev_pair=1 mixed=0"*) return 1 ;;
	esac
	return 2
}

p2p_member_state() {   # p2p_member_state /dev/ms0 -> mdadm -D output
	"$MDADM" --detail "$1"
}

# p2p_ordinary_write <dev> <offset-bytes> <len-bytes> [hex-byte] -> rc 0 on
# success. An ORDINARY (non-P2P-tagged, O_DIRECT) write via xfs_io, used
# where a test wants a plain write with no P2P payload involved at all.
p2p_ordinary_write() {
	local dev="$1" off="$2" len="$3" byte="${4:-0x5a}"
	xfs_io -d -c "pwrite -S $byte $off $len" "$dev" >/dev/null 2>&1
}

# --- member-level sysfs helpers -------------------------------------------

# p2p_rd_dirs <array> -> one /sys/.../rdN dir per line
p2p_rd_dirs() {
	local arr="$1" d
	for d in "/sys/block/$(basename "$arr")/$P2P_SYSFS"/rd*; do
		[ -d "$d" ] && echo "$d"
	done
}

# p2p_rd_dir_for_dev <array> <devnode> -> the rdN dir backed by <devnode>,
# resolved via the "block" symlink each rdN exposes. The devnode is
# canonicalised first: /dev/mapper/* are symlinks to /dev/dm-N, and sysfs
# only knows the dm-N name, so basename on the raw argument finds nothing.
p2p_rd_dir_for_dev() {
	local arr="$1" dev="$2" want d
	want="$(readlink -f "/sys/class/block/$(basename "$(readlink -f "$dev")")" 2>/dev/null)"
	[ -n "$want" ] || return 1
	for d in $(p2p_rd_dirs "$arr"); do
		[ "$(readlink -f "$d/block" 2>/dev/null)" = "$want" ] && { echo "$d"; return 0; }
	done
	return 1
}

# p2p_bb_nonempty <bad_blocks-file> -> true (rc 0) if any range is listed
p2p_bb_nonempty() {
	[ -s "$1" ] && [ -n "$(tr -d '[:space:]' <"$1")" ]
}

# p2p_bb_all_empty <array> -> true iff every member's bad_blocks is empty
p2p_bb_all_empty() {
	local arr="$1" d
	for d in $(p2p_rd_dirs "$arr"); do
		p2p_bb_nonempty "$d/bad_blocks" && return 1
	done
	return 0
}

# p2p_bb_count_entries <bad_blocks-file> -> number of badblock ranges
p2p_bb_count_entries() {
	[ -e "$1" ] || { echo 0; return; }
	grep -c '[0-9]' "$1" 2>/dev/null || echo 0
}

# p2p_bb_covers <bad_blocks-file> <sector> <len> -> rc 0 iff the whole
# [sector, sector+len) range is contained in the union of listed ranges.
# (Straightforward linear coverage check; the ranges in bad_blocks are not
# guaranteed sorted or merged, so this greedily extends a covered prefix.)
p2p_bb_covers() {
	local file="$1" want_s="$2" want_len="$3" cur end s l progressed
	[ -e "$file" ] || return 1
	cur="$want_s"
	end=$((want_s + want_len))
	progressed=1
	while [ "$cur" -lt "$end" ] && [ "$progressed" -eq 1 ]; do
		progressed=0
		while IFS=' ' read -r s l; do
			[ -n "$s" ] || continue
			if [ "$s" -le "$cur" ] && [ $((s + l)) -gt "$cur" ]; then
				cur=$((s + l))
				progressed=1
			fi
		done <"$file"
	done
	[ "$cur" -ge "$end" ]
}

p2p_is_faulty() {   # p2p_is_faulty <rd-dir>
	grep -q '\bfaulty\b' "$1/state" 2>/dev/null
}

p2p_wants_replacement() {   # p2p_wants_replacement <rd-dir>
	grep -q '\bwant_replacement\b' "$1/state" 2>/dev/null
}

# --- advertise policy / diagnosability ------------------------------------

P2P_ADVERTISE_PARAM="/sys/module/$P2P_CORE_MOD/parameters/p2pdma_advertise"

p2p_advertise_get() { cat "$P2P_ADVERTISE_PARAM" 2>/dev/null; }

p2p_advertise_set() {   # p2p_advertise_set auto|always|never
	echo "$1" >"$P2P_ADVERTISE_PARAM" || p2p_fail "cannot set p2pdma_advertise=$1"
}

p2p_status_file() {   # p2p_status_file <array> -> path to p2pdma_status
	echo "/sys/block/$(basename "$1")/$P2P_SYSFS/p2pdma_status"
}

# --- raw, below-md leg comparison (the divergence oracle) -----------------

# p2p_raw_cmp <dev> <sector> <dev2> <sector2> <nsectors> -> rc 0 iff the
# raw bytes at each location are byte-identical. Bypasses md entirely.
p2p_raw_cmp() {
	local d1="$1" s1="$2" d2="$3" s2="$4" n="$5"
	cmp -s \
		<(dd if="$d1" bs=512 skip="$s1" count="$n" status=none 2>/dev/null) \
		<(dd if="$d2" bs=512 skip="$s2" count="$n" status=none 2>/dev/null)
}

# p2p_raw_hex <dev> <sector> <nsectors> -> lowercase hex dump of the raw
# bytes, no spaces/newlines. Small ranges only (used for byte-pattern
# checks, not bulk comparison). od needs -v: its default duplicate-line
# suppression turns any uniform range into "<16 bytes>*", which can never
# equal a full-length expected pattern.
p2p_raw_hex() {
	dd if="$1" bs=512 skip="$2" count="$3" status=none 2>/dev/null \
		| od -An -v -tx1 | tr -d ' \n'
}

# p2p_pattern_hex <nsectors> <hex-byte> -> the hex dump p2p_raw_hex would
# produce if every byte in the range equals <hex-byte> (e.g. "a5").
p2p_pattern_hex() {
	local n=$(( $1 * 512 )) byte="$2" out
	printf -v out '%*s' "$n" ''
	echo "${out// /$byte}"
}

# p2p_raw_all_byte <dev> <sector> <nsectors> <hex-byte> -> rc 0 iff every
# byte in the range equals <hex-byte>.
p2p_raw_all_byte() {
	[ "$(p2p_raw_hex "$1" "$2" "$3")" = "$(p2p_pattern_hex "$3" "$4")" ]
}

# p2p_write_pattern <dev> <sector> <nsectors> <hex-byte> -- writes the
# given fill byte over the given sector range via an ORDINARY (non-P2P)
# write, i.e. entirely independent of anything this suite is testing.
# Used to seed known-good data before a P2P READ test.
p2p_write_pattern() {
	local dev="$1" sec="$2" n="$3" byte="$4" oct
	oct=$(printf '%03o' "$((16#$byte))")
	dd if=/dev/zero bs=512 count="$n" status=none 2>/dev/null \
		| tr '\000' "\\$oct" \
		| dd of="$dev" bs=512 seek="$sec" conv=notrunc status=none 2>/dev/null
}

# p2p_leg_safe <leg-dev> <leg-sector> <nsectors> <hex-fill-byte> <bad_blocks-file>
# -> rc 0 iff EITHER this leg's raw bytes match the expected pattern, OR
# its bad_blocks file is non-empty (i.e. NOT "wrong data with nothing on
# record to say so" -- the exact silent-divergence failure mode this
# design exists to prevent). Deliberately loose ("non-empty", not exact
# range coverage) -- good enough as a mechanism-agnostic safety net for
# real-topology tests where the precise leg status isn't under our
# control. test_divergence_oracle.sh and test_narrow_write_error_reentry.sh
# use the stricter p2p_bb_covers for exact-range verification instead.
p2p_leg_safe() {
	local dev="$1" sec="$2" n="$3" byte="$4" bbfile="$5"
	p2p_raw_all_byte "$dev" "$sec" "$n" "$byte" && return 0
	p2p_bb_nonempty "$bbfile"
}

# p2p_data_offset_sectors <array-member-devnode> -> that rdev's Data Offset
# (sectors), i.e. the translation from an array-relative sector to a
# physical sector on that leg. Parsed from `mdadm --examine`.
p2p_data_offset_sectors() {
	"$MDADM" --examine "$1" 2>/dev/null \
		| sed -n 's/^ *Data Offset : \([0-9]*\).*/\1/p' | head -1
}

# --- hot-add / hot-remove ---------------------------------------------------

p2p_hot_remove() {   # p2p_hot_remove <array> <devnode>
	local arr="$1" dev="$2"
	"$MDADM" "$arr" --fail "$dev" >/dev/null 2>&1
	"$MDADM" "$arr" --remove "$dev" >/dev/null 2>&1
}

p2p_hot_add() {   # p2p_hot_add <array> <devnode>
	"$MDADM" "$1" --add "$2" >/dev/null 2>&1
}
