#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
#
# TDD Fix B — every dkms/patches/*.patch must apply to the current
# drivers/md/ manifest sources, in glob order, with `patch -p1 --fuzz=0`,
# producing NO fuzz, NO reject, and NO apply offset.
#
# Why: the patches were authored against an older drivers/md/ snapshot.
# `patch` then lands hunks by its fuzz/offset heuristics — 0004 landed on
# a non-unique context by fuzz, 0005 landed by fuzz 2 because 0002 (applied
# first) had already rewritten its context. A fuzzy "success" can silently
# mis-target a hunk. Regenerating the patches against the current sources
# resets every hunk to an exact, zero-fuzz, zero-offset apply, and this
# test is the regression guard. See .full-review findings F2 / F3 / F4 /
# A4 / A5.

set -u
# shellcheck source=tools/testing/selftests/dkms/lib.sh
. "$(dirname "$0")/lib.sh"

tree="$(dkms_flat_manifest_tree)"

if ! out="$(dkms_apply_all_patches "$tree")"; then
	echo "FAIL: a patch failed to apply with --fuzz=0" >&2
	echo "$out" >&2
	exit 1
fi

assert_not_contains "$out" "fuzz" \
	"patches must apply with no fuzz under --fuzz=0"$'\n'"$out"
assert_not_contains "$out" "FAILED" \
	"patches must apply with no rejected hunks"$'\n'"$out"
# GNU patch prints "(offset N lines)" only when a hunk lands off its header
# line — i.e. the patch is stale relative to drivers/md/.
assert_not_contains "$out" "offset" \
	"patches must be in sync with drivers/md/ (no apply offset)"$'\n'"$out"

dkms_pass "all 7 patches apply in glob order with --fuzz=0, no fuzz, no offset"
