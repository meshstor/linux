#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
# nvme-tcp loopback raid1 perf harness for meshstor-ms.
# Spec: docs/superpowers/specs/2026-05-04-perf-bench-tcp-loopback-design.md
#
# Builds an ms raid1 with one local NVMe partition leg and one nvme-tcp
# loopback leg (the second partition exported via nvmet-tcp on this host
# and re-imported), then runs one or more csi-perf-test-style suites
# against /dev/ms0. Idempotent trap-driven teardown.

set -euo pipefail

# ---- defaults ----
# Consumed by parse_args (added in a later commit).
# shellcheck disable=SC2034
DEFAULT_BITMAP="lockless"
# shellcheck disable=SC2034
DEFAULT_PORT="4420"
# shellcheck disable=SC2034
DEFAULT_ADDR="127.0.0.1"

usage() {
    cat <<'EOF'
Usage: run-perf-bench-tcp.sh [flags] PART_LOCAL PART_REMOTE SUITE [SUITE...]

Builds an ms raid1 with PART_LOCAL as leg 0 and PART_REMOTE (exported via
nvmet-tcp on this host and re-imported) as leg 1, then runs each SUITE
(prepare.sh, run.sh, cleanup.sh) against /dev/ms0 in block mode.

Flags:
  --bitmap=VAL        passed verbatim to msadm --bitmap (default: lockless)
  --out-dir=PATH      results root (default: ./results/<UTC>-<host>-<kver>)
  --port=N            nvmet tcp port (default: 4420)
  --addr=IP           nvmet tcp listen addr (default: 127.0.0.1)
  --msadm=PATH        msadm binary (default: /tmp/msadm if exists, else PATH)
  --fail-fast         stop after first failing suite (default: continue)
  --keep              skip teardown on success (debugging only)
  -h, --help          this message

Exit codes:
  0   all suites passed
  2   usage error
  3   preflight failure
  4   setup failure (nvmet/nvme/msadm)
  5   one or more suites failed
EOF
}

main() {
    if [[ $# -eq 0 ]] || [[ "${1:-}" == "-h" ]] || [[ "${1:-}" == "--help" ]]; then
        usage
        exit 0
    fi
    echo "main: unimplemented" >&2
    exit 1
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
