#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
# Unit: preflight() rejects when tools missing, partitions don't exist,
# args are unsuitable. Stubs simulate root + tool presence.
set -e
# shellcheck source=tools/testing/selftests/perf-bench-tcp/lib.sh
. "$(dirname "$0")/lib.sh"
pbt_run_test "preflight"

# shellcheck source=dkms/scripts/run-perf-bench-tcp.sh
. "$PBT_SCRIPT"

# Stub all required tools as present + happy
for t in mdadm nvme fio lsblk jq udevadm awk modprobe ss; do
    pbt_stub "$t" 0 ""
done
pbt_stub msadm 0 ""

# preflight references real block devices and root-only system state.
# These env vars short-circuit those checks for unit tests.
export PBT_PRESUME_BLOCK=1
export PBT_SKIP_ROOT_CHECK=1

# Set required globals as parse_args would
LOCALS=(/tmp/p0)
REMOTES=(/tmp/p1)
SUITES=("$PBT_TMPDIR/suiteA")
mkdir -p "${SUITES[0]}"
for f in prepare.sh run.sh cleanup.sh; do
    : > "${SUITES[0]}/$f"
    chmod +x "${SUITES[0]}/$f"
done

# Happy path
preflight
echo "preflight ok (happy path)"

# Suite missing run.sh
rm "${SUITES[0]}/run.sh"
if (preflight) 2>/dev/null; then
    echo "FAIL: should reject suite without run.sh" >&2; exit 1
fi
: > "${SUITES[0]}/run.sh"; chmod +x "${SUITES[0]}/run.sh"

# Missing tool — append a fake name to REQUIRED_TOOLS. We can't simulate
# "missing" by removing a stub: the real tool may exist on the system PATH.
REQUIRED_TOOLS+=(definitely_not_a_real_tool_xyzzy_pbt)
if (preflight) 2>/dev/null; then
    echo "FAIL: should reject when a required tool is missing" >&2; exit 1
fi
unset 'REQUIRED_TOOLS[-1]'

echo "ok"
