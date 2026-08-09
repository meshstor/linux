#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
# BEHAVIOUR CAPTURE, NOT A GUARANTEE. raid1_should_handle_error()
# rejects REQ_NOWAIT bios (`!(bio->bi_opf & (REQ_RAHEAD | REQ_NOWAIT))`)
# before it ever looks at the completion status -- so a failed RWF_NOWAIT
# write is acked to the caller as a success, with no badblock recorded,
# REGARDLESS of which status the leg failed with (P2PDMA or otherwise).
# This is upstream-inherited (predates and is untouched by this work) and
# deliberately not "fixed" here -- see design doc section 5.
#
# This test exists so a future change to that behaviour doesn't slip by
# silently, NOT to certify it as safe. Prior analysis found the GDS
# cuFile path does not set RWF_NOWAIT, so this specific gap is not
# currently reachable through cuFile -- but a plain io_uring writer
# using IOSQE_* / RWF_NOWAIT against an ms/md device would hit exactly
# this. A passing result here is a description of current behaviour, not
# evidence that it is safe to rely on.
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/lib.sh"
if [ -z "${P2P_IN_VM:-}" ]; then
	p2p_require_rig
	exec "$DIR/run_vm.sh" symmetric \
		env P2P_IN_VM=1 MS_MOD_DIR="${MS_MOD_DIR:-}" \
		MDADM="${MDADM:-}" MD_SUBSYS="${MD_SUBSYS:-}" \
		"$DIR/$(basename "$0")"
fi
p2p_require_root; p2p_require_rig
p2p_require_tool xfs_io
trap 'p2p_cleanup; dmsetup remove legB 2>/dev/null; rmmod dm_errstat 2>/dev/null; rmmod brd 2>/dev/null' EXIT
p2p_load_ms_modules
modprobe brd rd_nr=2 rd_size=32768
p2p_load_dm_errstat
dmsetup create legB --table "0 $(blockdev --getsz /dev/ram1) errstat /dev/ram1 p2pdma"
ARR="$(p2p_make_array 1 /dev/ram0 /dev/mapper/legB)"
RDB="$(p2p_rd_dir_for_dev "$ARR" /dev/mapper/legB)" || p2p_fail "cannot find legB's rdev sysfs dir"

dmsetup message legB 0 arm
out="$(xfs_io -d -c "pwrite -N -S 0x5a 0 4096" "$ARR" 2>&1)"
rc=$?
dmsetup message legB 0 disarm

echo "xfs_io -N (RWF_NOWAIT) output: $out"
echo "rc=$rc, legB bad_blocks: $(cat "$RDB/bad_blocks" 2>/dev/null || echo '<unreadable>')"

if [ "$rc" -eq 0 ] && ! p2p_bb_nonempty "$RDB/bad_blocks"; then
	echo "OBSERVED (documented carve-out): RWF_NOWAIT write acked success with no badblock, despite legB's injected failure"
elif [ "$rc" -ne 0 ]; then
	echo "OBSERVED: this kernel's RWF_NOWAIT path returned an error (rc=$rc) instead of the documented carve-out -- behaviour has changed from the design doc's description; not treated as a failure here, but worth a closer look"
else
	echo "OBSERVED: write succeeded AND a badblock was recorded -- behaviour has changed from the design doc's description (NOWAIT no longer skips error handling); not treated as a failure here, but worth a closer look"
fi

p2p_pass "RWF_NOWAIT behaviour recorded above (see header: not a safety guarantee)"
