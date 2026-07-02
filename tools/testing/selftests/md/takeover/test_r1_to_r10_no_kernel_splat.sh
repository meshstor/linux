#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
# A successful takeover must NOT log any WARN/BUG/Oops splats. The
# helper does the personality swap while suspended, but the wrong
# ordering between setup_conf/mddev_detach/oldpers->free is a common
# source of refcount or sysfs-attribute splats.
. "$(dirname "$0")/lib.sh"
md_require_root
md_require_tools
md_require_modules

loop0="$(md_make_loop 64)"
loop1="$(md_make_loop 64)"
MD_TEST_MD_DEV="$(md_find_free_md_dev)"

md_mdadm --create --run --metadata=1.2 --level=1 --raid-devices=2 \
	"$MD_TEST_MD_DEV" "$loop0" "$loop1" >/dev/null 2>&1 \
	|| md_fail "could not create raid1"
md_wait_sync "$MD_TEST_MD_DEV"

# Drain ring buffer noise so we only see splats from THIS takeover.
md_clear_dmesg

sysfs="$(md_sysfs_path "$MD_TEST_MD_DEV")"
md_sysfs_write "$sysfs/level" raid10 \
	|| md_fail "takeover failed"

# A silently no-op'd takeover produces no splat either; confirm the
# level actually changed so "no splat" is not vacuously true.
level="$(md_sysfs_read "$sysfs/level")"
[ "$level" = "raid10" ] || md_fail "level not raid10 after takeover: $level"

# Let any async splat surface.
sleep 1

# Match canonical splat markers positively and case-sensitively, and
# do NOT filter out md lines: a WARN fired in this code reports as
# "WARNING: CPU: N PID: N at drivers/md/raid10.c:..." and is exactly
# what this test exists to catch. Benign md log text (pr_warn/pr_crit
# messages) never contains these markers.
bad="$(dmesg 2>/dev/null \
	| grep -E 'WARNING:|BUG:|kernel BUG at|Oops:|general protection fault|RIP:|Call Trace:' \
	| head -5)"
if [ -n "$bad" ]; then
	echo "$bad" >&2
	md_fail "kernel splat detected during takeover"
fi

md_pass "successful takeover produced no kernel splat"
