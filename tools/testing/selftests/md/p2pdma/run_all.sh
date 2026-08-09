#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
# Run every p2pdma selftest in this directory and summarise.
# Exit 0 iff no test FAILed (SKIPs are tolerated, exit code 4).
#
# Each test boots its own QEMU VM (see run_vm.sh) and loads/unloads kernel
# modules; a wedged retry path can hang a test indefinitely, so every test
# is bounded by $P2P_TEST_TIMEOUT (default 300s, kselftest convention: a
# timeout is reported as a FAIL, not a SKIP).
#
# The timeout signal is the DEFAULT SIGTERM, escalating to SIGKILL only
# after $P2P_TEST_KILL_AFTER. It must not be `--signal=KILL`: the test has
# exec'd run_vm.sh, which runs vng -> virtme-run -> qemu-system-x86, and
# SIGKILL gives that chain no chance to tear the VM down. Anything that
# leaves the group (or that timeout cannot signal) survives as an orphaned
# QEMU burning a core until someone notices -- this repo has been bitten by
# multi-hour orphans. SIGTERM lets vng/virtme-run reap qemu first, and the
# --kill-after escalation still guarantees the harness makes progress.
# Neither 124 (SIGTERM timeout) nor 137 (SIGKILL) is 4, so a timeout is
# still counted as a FAIL, not a SKIP.
#
# A rigless box now skips WITHOUT booting anything: every test calls
# p2p_require_rig on the host, above its `exec run_vm.sh` (see lib.sh).
#
#   sudo MD_SUBSYS=ms MS_MOD_DIR=/path/to/built/modules \
#       bash tools/testing/selftests/md/p2pdma/run_all.sh
set -u
cd "$(dirname "$0")" || exit 2

P2P_TEST_TIMEOUT="${P2P_TEST_TIMEOUT:-300}"
P2P_TEST_KILL_AFTER="${P2P_TEST_KILL_AFTER:-30}"

pass=0 fail=0 skip=0 failed=()
for t in test_*.sh; do
	[ -e "$t" ] || continue
	echo "=== $t ==="
	if timeout --kill-after="$P2P_TEST_KILL_AFTER" "$P2P_TEST_TIMEOUT" bash "$t"; then
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

echo "--- p2pdma selftests: pass=$pass fail=$fail skip=$skip ---"
if [ "$fail" -ne 0 ]; then
	printf 'FAILED: %s\n' "${failed[@]}" >&2
	exit 1
fi
exit 0
