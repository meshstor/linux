#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
# Unit: msraid_assemble passes correct flags to msadm; msraid_verify
# rejects non-active state; teardown is idempotent.
set -e
# shellcheck source=tools/testing/selftests/perf-bench-tcp/lib.sh
. "$(dirname "$0")/lib.sh"
pbt_run_test "msraid"

# shellcheck source=dkms/scripts/run-perf-bench-tcp.sh
. "$PBT_SCRIPT"

MSADM="$PBT_STUB_DIR/msadm"
PART_LOCAL=/dev/p0
IMPORTED=/dev/p1
BITMAP=lockless
MS_DEV=/dev/ms0

# Happy assemble
pbt_stub msadm 0 ""
msraid_assemble
log_out="$(pbt_stub_log)"
pbt_assert_contains "$log_out" \
    "STUB msadm --create /dev/ms0 --level=raid1 --raid-devices=2 --bitmap=lockless --metadata=1.2 --run --assume-clean /dev/p0 /dev/p1" \
    "msadm --create args"

# Verify happy: state=active, working=2
detail_ok="State : active
Working Devices : 2
Failed Devices : 0"
pbt_stub msadm 0 "$detail_ok"
msraid_verify
echo "verify ok (happy)"

# Verify failing: degraded
detail_bad="State : clean, degraded
Working Devices : 1
Failed Devices : 1"
pbt_stub msadm 0 "$detail_bad"
if (msraid_verify) 2>/dev/null; then
    echo "FAIL: msraid_verify should reject degraded" >&2; exit 1
fi

# Teardown is idempotent (no-op if not assembled)
MSRAID_ASSEMBLED=0
msraid_teardown
echo "teardown idempotent ok"

MSRAID_ASSEMBLED=1
pbt_stub msadm 0 ""
msraid_teardown
log_out2="$(pbt_stub_log)"
pbt_assert_contains "$log_out2" "STUB msadm --stop /dev/ms0" "msadm --stop"
pbt_assert_contains "$log_out2" "STUB msadm --zero-superblock /dev/p0" "zero local"
pbt_assert_contains "$log_out2" "STUB msadm --zero-superblock /dev/p1" "zero imported"

echo "ok"
