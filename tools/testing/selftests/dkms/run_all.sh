#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
# Run every meshstor-ms DKMS tooling selftest in this directory and summarise.
# Exit 0 iff no test FAILed (SKIPs are tolerated).
set -u
cd "$(dirname "$0")" || exit 2

pass=0 fail=0 skip=0 failed=()
for t in test_*.sh; do
	[ -e "$t" ] || continue
	echo "=== $t ==="
	if bash "$t"; then
		pass=$((pass + 1))
	else
		rc=$?
		if [ "$rc" -eq 4 ]; then
			skip=$((skip + 1))
		else
			fail=$((fail + 1))
			failed+=("$t")
		fi
	fi
	echo
done

echo "--- dkms tooling selftests: pass=$pass fail=$fail skip=$skip ---"
if [ "$fail" -ne 0 ]; then
	printf 'FAILED: %s\n' "${failed[@]}" >&2
	exit 1
fi
exit 0
