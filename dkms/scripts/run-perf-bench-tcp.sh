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

# ---- logging ----
LOG_FD=2  # stderr by default; main() may redirect later

log()  { printf '[%s] %s\n' "$(date -u +%FT%TZ)" "$*" >&"$LOG_FD"; }
warn() { printf '[%s] WARN: %s\n' "$(date -u +%FT%TZ)" "$*" >&"$LOG_FD"; }

# run_log CMD ARGS...  — log the command, then run it; output goes
# wherever the caller already routed stdout/stderr. Returns command's
# exit code.
run_log() {
    log "+ $*"
    "$@"
}

# ---- preflight ----
REQUIRED_TOOLS=(mdadm nvme fio lsblk jq udevadm awk modprobe ss)
REQUIRED_MODULES=(nvmet nvmet-tcp nvme-tcp ms-mod)

die_pre() { echo "preflight: $*" >&2; exit "$EXIT_PREFLIGHT"; }

resolve_msadm() {
    if [[ -n "$MSADM" ]]; then
        [[ -x "$MSADM" ]] || return 1
        return 0
    fi
    if [[ -x /tmp/msadm ]]; then
        MSADM=/tmp/msadm
        return 0
    fi
    if command -v msadm >/dev/null 2>&1; then
        MSADM="$(command -v msadm)"
        return 0
    fi
    return 1
}

preflight() {
    if [[ "${PBT_SKIP_ROOT_CHECK:-0}" != "1" ]] && [[ "$(id -u)" -ne 0 ]]; then
        die_pre "must run as root"
    fi

    local t
    for t in "${REQUIRED_TOOLS[@]}"; do
        command -v "$t" >/dev/null 2>&1 || die_pre "missing tool: $t"
    done

    if ! resolve_msadm; then
        die_pre "msadm not found (tried --msadm, /tmp/msadm, PATH)"
    fi

    local m
    for m in "${REQUIRED_MODULES[@]}"; do
        if ! modprobe -n "$m" >/dev/null 2>&1; then
            die_pre "kernel module not loadable: $m"
        fi
    done

    local p
    for p in "$PART_LOCAL" "$PART_REMOTE"; do
        if [[ "${PBT_PRESUME_BLOCK:-0}" != "1" ]] && [[ ! -b "$p" ]]; then
            die_pre "not a block device: $p"
        fi
        if grep -q "^$(basename "$p") " /proc/mdstat 2>/dev/null; then
            die_pre "partition is in /proc/mdstat: $p"
        fi
        if awk '{print $10}' /proc/self/mountinfo 2>/dev/null | grep -qx "$p"; then
            die_pre "partition is mounted: $p"
        fi
    done

    local s f
    for s in "${SUITES[@]}"; do
        [[ -d "$s" ]] || die_pre "suite is not a directory: $s"
        for f in prepare.sh run.sh cleanup.sh; do
            [[ -x "$s/$f" ]] || die_pre "suite missing executable $f: $s"
        done
    done

    if [[ "${PBT_SKIP_ROOT_CHECK:-0}" != "1" ]]; then
        if ss -lnt "sport = :$PORT" 2>/dev/null | tail -n +2 | grep -q .; then
            die_pre "port already bound: $ADDR:$PORT"
        fi
    fi
}

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

    # Mark not-yet-consumed globals as "used" so shellcheck SC2034
    # doesn't flag them while later commits add the actual consumers
    # (setup_nvmet, run_suite, cleanup, ...). The final commit will
    # remove this line once every global has a real reader.
    : "$BITMAP $OUT_DIR $FAIL_FAST $KEEP $EXIT_SETUP $EXIT_SUITE"
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
