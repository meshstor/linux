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
DEFAULT_BITMAP="lockless"
DEFAULT_PORT="4420"
DEFAULT_ADDR="127.0.0.1"

# ---- exit codes ----
EXIT_USAGE=2
EXIT_PREFLIGHT=3
EXIT_SETUP=4
EXIT_SUITE=5

# ---- globals populated by parse_args ----
PART_LOCAL=""
PART_REMOTE=""
SUITES=()
BITMAP="$DEFAULT_BITMAP"
PORT="$DEFAULT_PORT"
ADDR="$DEFAULT_ADDR"
MSADM=""
OUT_DIR=""
FAIL_FAST=0
KEEP=0

die() { echo "error: $*" >&2; exit "$EXIT_USAGE"; }

parse_args() {
    # Reset state so callers (and tests) can invoke parse_args repeatedly.
    PART_LOCAL=""
    PART_REMOTE=""
    SUITES=()
    BITMAP="$DEFAULT_BITMAP"
    PORT="$DEFAULT_PORT"
    ADDR="$DEFAULT_ADDR"
    MSADM=""
    OUT_DIR=""
    FAIL_FAST=0
    KEEP=0

    local pos=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --bitmap=*)   BITMAP="${1#--bitmap=}" ;;
            --port=*)     PORT="${1#--port=}" ;;
            --addr=*)     ADDR="${1#--addr=}" ;;
            --out-dir=*)  OUT_DIR="${1#--out-dir=}" ;;
            --msadm=*)    MSADM="${1#--msadm=}" ;;
            --fail-fast)  FAIL_FAST=1 ;;
            --keep)       KEEP=1 ;;
            -h|--help)    usage; exit 0 ;;
            --) shift; pos+=("$@"); break ;;
            -*) die "unknown flag: $1" ;;
            *)  pos+=("$1") ;;
        esac
        shift
    done

    if [[ ${#pos[@]} -lt 3 ]]; then
        die "need PART_LOCAL PART_REMOTE SUITE [SUITE...]; got ${#pos[@]} positional args"
    fi
    PART_LOCAL="${pos[0]}"
    PART_REMOTE="${pos[1]}"
    SUITES=("${pos[@]:2}")

    if [[ "$PART_LOCAL" == "$PART_REMOTE" ]]; then
        die "PART_LOCAL and PART_REMOTE must differ"
    fi

    # Mark globals as "used" so shellcheck SC2034 doesn't flag them
    # while later commits add the actual consumers (preflight,
    # setup_nvmet, run_suite, cleanup, ...). The next-to-last commit
    # will remove this line once every global has a real reader.
    : "$BITMAP $PORT $ADDR $MSADM $OUT_DIR $FAIL_FAST $KEEP ${SUITES[*]}" \
      "$PART_LOCAL $PART_REMOTE $EXIT_PREFLIGHT $EXIT_SETUP $EXIT_SUITE"
}

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
    parse_args "$@"
    echo "main: unimplemented (parse_args ok)" >&2
    exit 1
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
