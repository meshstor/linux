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

# resolve_imported uses `nvme list-subsys -o json` and assembles
# /dev/<ctl>n1; PBT_PRESUME_BLOCK skips the [-b] check on the resulting
# path so /dev/nvme9n1 (a fictional path) is accepted in unit tests.
export PBT_PRESUME_BLOCK=1

REMOTES=(/dev/p1)
list_subsys_json='[
  {"Subsystems":[
    {"Name":"nvme-subsys0","NQN":"nqn.other:x","Paths":[{"Name":"nvme0"}]},
    {"Name":"nvme-subsys1","NQN":"nqn.test:demo","Paths":[{"Name":"nvme9"}]}
  ]}
]'
pbt_stub nvme 0 "$list_subsys_json"
resolve_imported
pbt_assert_eq "${IMPORTEDS[0]}" "/dev/nvme9n1" "IMPORTEDS[0] resolved by NQN"
pbt_assert_eq "${#IMPORTEDS[@]}" "1" "1 import for raid1"

# Multi-namespace (raid10): 2 remotes → 2 imports under same controller
REMOTES=(/dev/p1 /dev/p2)
pbt_stub nvme 0 "$list_subsys_json"
resolve_imported
pbt_assert_eq "${#IMPORTEDS[@]}" "2" "raid10 2 imports"
pbt_assert_eq "${IMPORTEDS[0]}" "/dev/nvme9n1" "raid10 IMPORTEDS[0]"
pbt_assert_eq "${IMPORTEDS[1]}" "/dev/nvme9n2" "raid10 IMPORTEDS[1]"

# Reset
REMOTES=(/dev/p1)

# Zero matches → fail
list_subsys_json='[{"Subsystems":[{"NQN":"nqn.other:x","Paths":[{"Name":"nvme0"}]}]}]'
pbt_stub nvme 0 "$list_subsys_json"
if (resolve_imported) 2>/dev/null; then
    echo "FAIL: should error on zero matches" >&2; exit 1
fi

# Two matches → fail
list_subsys_json='[{"Subsystems":[
  {"NQN":"nqn.test:demo","Paths":[{"Name":"nvme9"}]},
  {"NQN":"nqn.test:demo","Paths":[{"Name":"nvme8"}]}
]}]'
pbt_stub nvme 0 "$list_subsys_json"
if (resolve_imported) 2>/dev/null; then
    echo "FAIL: should error on multiple matches" >&2; exit 1
fi

echo "ok"
