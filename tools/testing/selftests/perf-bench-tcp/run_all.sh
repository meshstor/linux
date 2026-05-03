#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
# Run every test_*.sh in this dir; exit non-zero on any failure.
set -u
cd "$(dirname "$0")" || exit 2
fail=0
for t in test_*.sh; do
    [ -e "$t" ] || continue
    if bash "$t"; then
        echo "PASS $t"
    else
        echo "FAIL $t" >&2
        fail=1
    fi
done
exit "$fail"
