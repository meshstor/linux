#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
# Unit: cleanup invokes teardown in correct order; --keep skips it on
# success path only.
set -e
# shellcheck source=tools/testing/selftests/perf-bench-tcp/lib.sh
. "$(dirname "$0")/lib.sh"
pbt_run_test "cleanup"

# shellcheck source=dkms/scripts/run-perf-bench-tcp.sh
. "$PBT_SCRIPT"

OUT_DIR="$PBT_TMPDIR/results"; mkdir -p "$OUT_DIR"
MSADM="$PBT_STUB_DIR/msadm"
LOCALS=(/tmp/p0)
IMPORTEDS=(/tmp/p1-imp)
NQN=nqn.test:demo
NVMET_ROOT="$PBT_TMPDIR/configfs"
PORT_ID=12345
mkdir -p "$NVMET_ROOT/subsystems/$NQN/namespaces/1"
mkdir -p "$NVMET_ROOT/ports/$PORT_ID/subsystems"
ln -s "../../subsystems/$NQN" "$NVMET_ROOT/ports/$PORT_ID/subsystems/$NQN"

pbt_stub msadm 0 ""
pbt_stub nvme  0 ""
pbt_stub udevadm 0 ""

NVMET_SETUP_DONE=1
NVME_CONNECTED=1
MSRAID_ASSEMBLED=1
KEEP=0
SUITE_FAILURES=0

cleanup
log_out="$(pbt_stub_log)"

pbt_assert_contains "$log_out" "STUB msadm --stop /dev/ms0"               "msadm --stop"
pbt_assert_contains "$log_out" "STUB msadm --zero-superblock /tmp/p0"     "zero local"
pbt_assert_contains "$log_out" "STUB msadm --zero-superblock /tmp/p1-imp" "zero imported"
pbt_assert_contains "$log_out" "STUB nvme disconnect -n nqn.test:demo"    "nvme disconnect"

# configfs torn down
[ ! -L "$NVMET_ROOT/ports/$PORT_ID/subsystems/$NQN" ] || { echo "FAIL: port symlink remains"; exit 1; }
[ ! -d "$NVMET_ROOT/ports/$PORT_ID" ]                  || { echo "FAIL: port dir remains";     exit 1; }
[ ! -d "$NVMET_ROOT/subsystems/$NQN/namespaces/1" ]    || { echo "FAIL: ns dir remains";       exit 1; }
[ ! -d "$NVMET_ROOT/subsystems/$NQN" ]                 || { echo "FAIL: sub dir remains";      exit 1; }

# --keep + success path → skip teardown
mkdir -p "$NVMET_ROOT/subsystems/$NQN/namespaces/1"
mkdir -p "$NVMET_ROOT/ports/$PORT_ID/subsystems"
NVMET_SETUP_DONE=1; NVME_CONNECTED=1; MSRAID_ASSEMBLED=1
KEEP=1
SCRIPT_RC=0
cleanup
[ -d "$NVMET_ROOT/subsystems/$NQN" ] || { echo "FAIL: --keep should preserve nvmet"; exit 1; }

# --keep + failure path → still cleans up
NVMET_SETUP_DONE=1; NVME_CONNECTED=1; MSRAID_ASSEMBLED=1
KEEP=1
SCRIPT_RC=1
cleanup
[ ! -d "$NVMET_ROOT/subsystems/$NQN" ] || { echo "FAIL: --keep on failure should NOT preserve"; exit 1; }

echo "ok"
