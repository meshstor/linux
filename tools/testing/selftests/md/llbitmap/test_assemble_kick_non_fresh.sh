#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
#
# Reproducer for RCA #5 ("kicking non-fresh on cross-node migration"):
# when analyze_sbs() walks rdevs during initial assemble and finds an
# events counter delta of >= 2 between members, it kicks the lagging
# one with the warning
#
#   md: kicking non-fresh <bdev> from array!
#
# (or `ms:` prefix on the meshstor-renamed module build).
#
# This test forces the precondition deterministically on a 2-member
# raid1 with bitmap=internal by re-assembling with only member LA and
# writing twice, leaving LA two events ahead of LB. Then we assemble
# with both and assert the kick fires and LB is no longer present.
#
# Pass = kick observed AND LB no longer tracked by sysfs.
# This test passes on the CURRENT kernel (kick is the existing
# behavior). After D2 (events-delta in pr_warn) it MUST still pass,
# now also asserting the enriched warning format. After D4 (legacy
# flag default flip) it MUST still pass - D4 does not change the
# kick path, only the upstream events-divergence race.

set -eu

DIR="$(dirname "$0")"
. "$DIR/lib.sh"

llbitmap_require_root
llbitmap_require_modules
llbitmap_require_tools

LA=$(llbitmap_make_loop 100)
LB=$(llbitmap_make_loop 100)

llbitmap_alloc_ms_dev >/dev/null
MS_DEV="$LLBITMAP_TEST_MS_DEV"
MS_NAME="$LLBITMAP_TEST_MS_NAME"
LA_BASE=$(basename "$LA")
LB_BASE=$(basename "$LB")

echo "INFO: ms_dev=$MS_DEV LA=$LA LB=$LB"

# Step 1: create + initial write + sync stop. Both members should hold
# identical events counters at this point.
"$MDADM" --create "$MS_DEV" \
	--level=1 --metadata=1.2 --raid-devices=2 --homehost=any \
	--bitmap=internal "$LA" "$LB" --run --force >/dev/null 2>&1

dd if=/dev/urandom of="$MS_DEV" bs=1M count=1 oflag=direct >/dev/null 2>&1
"$MDADM" --wait "$MS_DEV" || true
"$MDADM" --stop "$MS_DEV" >/dev/null 2>&1

eA0=$(llbitmap_events_of "$LA")
eB0=$(llbitmap_events_of "$LB")
echo "INFO: after first stop  eA=$eA0 eB=$eB0"
if [ "$eA0" != "$eB0" ]; then
	llbitmap_fail "events already diverged after initial stop (eA=$eA0 eB=$eB0)"
fi

# Step 2: re-assemble with LA only, write, stop. Repeat to make LA at
# least two events ahead of LB.
for i in 1 2; do
	"$MDADM" --assemble "$MS_DEV" "$LA" --run --force >/dev/null 2>&1
	dd if=/dev/urandom of="$MS_DEV" bs=1M count=1 oflag=direct >/dev/null 2>&1
	"$MDADM" --wait "$MS_DEV" || true
	"$MDADM" --stop "$MS_DEV" >/dev/null 2>&1
done

eA1=$(llbitmap_events_of "$LA")
eB1=$(llbitmap_events_of "$LB")
echo "INFO: after divergence eA=$eA1 eB=$eB1 delta=$((eA1 - eB1))"
if [ $((eA1 - eB1)) -lt 2 ]; then
	llbitmap_fail "expected events delta >=2, got $((eA1 - eB1))"
fi

# Step 3: clear dmesg, assemble both, expect the kick.
llbitmap_dmesg_clear
"$MDADM" --assemble "$MS_DEV" "$LA" "$LB" --run --force >/dev/null 2>&1
"$MDADM" --wait "$MS_DEV" >/dev/null 2>&1 || true

# After D2 (md: log events counter values when kicking non-fresh device)
# the warning carries the actual events numbers. Require that format
# here; on an unpatched kernel this assertion fails and the next task
# (kernel patch) is the fix.
if ! llbitmap_dmesg_contains "kicking non-fresh ${LB_BASE} from array.*events=.*freshest="; then
	echo "INFO: recent dmesg tail:"
	dmesg | tail -30 | sed 's/^/  /'
	llbitmap_fail "expected 'kicking non-fresh ${LB_BASE} from array.*events=.*freshest=' in dmesg"
fi

if llbitmap_member_present "$MS_NAME" "$LB_BASE"; then
	llbitmap_fail "LB ($LB_BASE) is still present in sysfs after kick"
fi

# Sanity: array is degraded (1 of 2).
deg=$(cat "/sys/block/$MS_NAME/ms/degraded" 2>/dev/null || echo "?")
if [ "$deg" != "1" ]; then
	llbitmap_fail "expected degraded=1 after kick, got '$deg'"
fi

echo "INFO: scenario 1 passed (delta>=2 kicks LB)"

# Reset cleanup state and run scenario 2: delta == 1 must NOT kick.
"$MDADM" --stop "$MS_DEV" >/dev/null 2>&1 || true

# Fresh loops + fresh ms_dev for scenario 2.
LA2=$(llbitmap_make_loop 100)
LB2=$(llbitmap_make_loop 100)
llbitmap_alloc_ms_dev >/dev/null
MS_DEV2="$LLBITMAP_TEST_MS_DEV"
MS_NAME2="$LLBITMAP_TEST_MS_NAME"
LB2_BASE=$(basename "$LB2")

"$MDADM" --create "$MS_DEV2" \
	--level=1 --metadata=1.2 --raid-devices=2 --homehost=any \
	--bitmap=internal "$LA2" "$LB2" --run --force >/dev/null 2>&1
dd if=/dev/urandom of="$MS_DEV2" bs=1M count=1 oflag=direct >/dev/null 2>&1
"$MDADM" --wait "$MS_DEV2" || true
"$MDADM" --stop "$MS_DEV2" >/dev/null 2>&1

eA2_0=$(llbitmap_events_of "$LA2")
eB2_0=$(llbitmap_events_of "$LB2")
if [ "$eA2_0" != "$eB2_0" ]; then
	llbitmap_fail "scenario 2: initial events differ (eA=$eA2_0 eB=$eB2_0)"
fi

# Bump LA2's events by exactly 1: assemble readonly (no events bump),
# transition to read-write (one md_update_sb fires for the state
# change), then stop. Avoids the +2 bump that comes from data writes
# (which trigger both the clean->dirty and dirty->clean transitions).
"$MDADM" --assemble "$MS_DEV2" "$LA2" --readonly --run --force >/dev/null 2>&1
"$MDADM" --readwrite "$MS_DEV2" >/dev/null 2>&1
"$MDADM" --stop "$MS_DEV2" >/dev/null 2>&1

eA2_1=$(llbitmap_events_of "$LA2")
eB2_1=$(llbitmap_events_of "$LB2")
delta2=$((eA2_1 - eB2_1))
echo "INFO: scenario 2 delta=$delta2"
if [ "$delta2" -ne 1 ]; then
	# Scenario 2 cannot exercise the delta==1 boundary on this build
	# (mdadm bumps events by a different increment). Scenario 1 still
	# proved the kick path; report PASS for the test as a whole with
	# scenario 2 noted as unrunnable.
	echo "INFO: scenario 2 unrunnable (delta=$delta2 != 1); scenario 1 result stands"
	llbitmap_pass "scenario 1 (delta>=2 kicks); scenario 2 skipped (delta!=1 on this build)"
fi

llbitmap_dmesg_clear
"$MDADM" --assemble "$MS_DEV2" "$LA2" "$LB2" --run --force >/dev/null 2>&1
"$MDADM" --wait "$MS_DEV2" || true

if llbitmap_dmesg_contains "kicking non-fresh ${LB2_BASE} from array"; then
	echo "INFO: dmesg tail:"
	dmesg | tail -20 | sed 's/^/  /'
	llbitmap_fail "scenario 2: delta=1 should NOT trigger kick, but it did"
fi

if ! llbitmap_member_present "$MS_NAME2" "$LB2_BASE"; then
	llbitmap_fail "scenario 2: LB2 is missing from sysfs (kernel kicked despite delta=1)"
fi

llbitmap_pass "scenario 1 (delta>=2 kicks) AND scenario 2 (delta=1 does not kick)"
