#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
# Unit: NQN format + port-id derivation are stable + collision-resistant.
set -e
# shellcheck source=tools/testing/selftests/perf-bench-tcp/lib.sh
. "$(dirname "$0")/lib.sh"
pbt_run_test "nvmet-helpers"

# shellcheck source=dkms/scripts/run-perf-bench-tcp.sh
. "$PBT_SCRIPT"

generate_nqn
case "$NQN" in
    nqn.2026-05.local:msbench-*-*-*) ;;
    *) echo "FAIL: NQN format: $NQN" >&2; exit 1 ;;
esac

ADDR=127.0.0.1; PORT=4420
generate_port_id
p1="$PORT_ID"
ADDR=127.0.0.1; PORT=4420
generate_port_id
p2="$PORT_ID"
pbt_assert_eq "$p1" "$p2" "port-id stable for same addr:port"

ADDR=127.0.0.1; PORT=5555
generate_port_id
p3="$PORT_ID"
if [ "$p1" = "$p3" ]; then
    echo "FAIL: port-id should differ for different ports" >&2; exit 1
fi

# Two NQN generations differ
generate_nqn; n1="$NQN"
generate_nqn; n2="$NQN"
if [ "$n1" = "$n2" ]; then
    echo "FAIL: NQN generation should not repeat" >&2; exit 1
fi

echo "ok"
