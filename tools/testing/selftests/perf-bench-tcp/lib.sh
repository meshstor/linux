# SPDX-License-Identifier: GPL-2.0
# shellcheck shell=bash
# Test helpers for run-perf-bench-tcp.sh unit tests.
# Sourced by test_*.sh; never run directly.

set -u

PBT_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
# Used by test_*.sh.
# shellcheck disable=SC2034
PBT_SCRIPT="$PBT_REPO_ROOT/dkms/scripts/run-perf-bench-tcp.sh"
PBT_TMPDIR=""
PBT_STUB_DIR=""
PBT_STUB_LOG=""

pbt_setup() {
    PBT_TMPDIR="$(mktemp -d "${TMPDIR:-/tmp}/pbt.XXXXXX")"
    PBT_STUB_DIR="$PBT_TMPDIR/stubs"
    PBT_STUB_LOG="$PBT_TMPDIR/stub.log"
    mkdir -p "$PBT_STUB_DIR"
    : > "$PBT_STUB_LOG"
    export PATH="$PBT_STUB_DIR:$PATH"
    export PBT_STUB_LOG
}

pbt_teardown() {
    if [ -n "$PBT_TMPDIR" ] && [ -d "$PBT_TMPDIR" ]; then
        rm -rf "$PBT_TMPDIR"
    fi
}

# pbt_stub NAME EXIT_CODE [STDOUT_BODY]
# Creates an executable stub on PATH that logs its argv to $PBT_STUB_LOG
# and exits with EXIT_CODE. STDOUT_BODY is printed verbatim to stdout
# (use empty string for nothing).
pbt_stub() {
    local name="$1" rc="$2" body="${3:-}"
    local path="$PBT_STUB_DIR/$name"
    {
        printf '#!/usr/bin/env bash\n'
        # The single quotes are intentional: $* and $PBT_STUB_LOG must
        # expand inside the generated stub at stub-run time, not now.
        # shellcheck disable=SC2016
        printf 'echo "STUB %s $*" >> "$PBT_STUB_LOG"\n' "$name"
        if [ -n "$body" ]; then
            printf 'cat <<'\''STUBBODY'\''\n%s\nSTUBBODY\n' "$body"
        fi
        printf 'exit %s\n' "$rc"
    } > "$path"
    chmod +x "$path"
}

pbt_stub_log() {
    cat "$PBT_STUB_LOG"
}

pbt_assert_eq() {
    local got="$1" want="$2" msg="${3:-assertion failed}"
    if [ "$got" != "$want" ]; then
        printf 'FAIL: %s\n  got:  %q\n  want: %q\n' "$msg" "$got" "$want" >&2
        exit 1
    fi
}

pbt_assert_contains() {
    local hay="$1" needle="$2" msg="${3:-substring not found}"
    case "$hay" in
        *"$needle"*) ;;
        *)
            printf 'FAIL: %s\n  needle: %q\n  in:     %q\n' "$msg" "$needle" "$hay" >&2
            exit 1
            ;;
    esac
}

pbt_assert_file_contains() {
    local path="$1" needle="$2" msg="${3:-file does not contain needle}"
    if ! grep -qF -- "$needle" "$path"; then
        printf 'FAIL: %s\n  needle: %q\n  file:   %s\n' "$msg" "$needle" "$path" >&2
        cat "$path" >&2
        exit 1
    fi
}

pbt_run_test() {
    local name="$1"
    pbt_setup
    trap 'pbt_teardown' EXIT
    echo "=== $name ==="
}
