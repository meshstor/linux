#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
# Unit: connect_nvme_client passes the right flags; resolve_imported
# extracts the device by NQN match.
set -e
# shellcheck source=tools/testing/selftests/perf-bench-tcp/lib.sh
. "$(dirname "$0")/lib.sh"
pbt_run_test "nvme-client"

# shellcheck source=dkms/scripts/run-perf-bench-tcp.sh
. "$PBT_SCRIPT"

NQN="nqn.test:demo"
ADDR=10.0.0.5
PORT=4420

pbt_stub nvme 0 ""
pbt_stub udevadm 0 ""

connect_nvme_client
log_out="$(pbt_stub_log)"
pbt_assert_contains "$log_out" "STUB nvme connect -t tcp -a 10.0.0.5 -s 4420 -n $NQN" \
                    "nvme connect args"
pbt_assert_contains "$log_out" "STUB udevadm settle" "udevadm settle called"

# resolve_imported uses `nvme list -o json`; stub returns matching JSON
nvme_list_json='{
  "Devices": [
    { "DevicePath": "/dev/nvme0n1", "SubsystemNQN": "nqn.other:x" },
    { "DevicePath": "/dev/nvme9n1", "SubsystemNQN": "nqn.test:demo" }
  ]
}'
pbt_stub nvme 0 "$nvme_list_json"
resolve_imported
pbt_assert_eq "$IMPORTED" "/dev/nvme9n1" "IMPORTED resolved by NQN"

# Zero matches → fail
nvme_list_json='{"Devices":[{"DevicePath":"/dev/nvme0n1","SubsystemNQN":"nqn.other:x"}]}'
pbt_stub nvme 0 "$nvme_list_json"
if (resolve_imported) 2>/dev/null; then
    echo "FAIL: should error on zero matches" >&2; exit 1
fi

# Two matches → fail
nvme_list_json='{"Devices":[
  {"DevicePath":"/dev/nvme9n1","SubsystemNQN":"nqn.test:demo"},
  {"DevicePath":"/dev/nvme8n1","SubsystemNQN":"nqn.test:demo"}]}'
pbt_stub nvme 0 "$nvme_list_json"
if (resolve_imported) 2>/dev/null; then
    echo "FAIL: should error on multiple matches" >&2; exit 1
fi

echo "ok"
