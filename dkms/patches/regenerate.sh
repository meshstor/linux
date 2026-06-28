#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
#
# Re-sync dkms/patches/*.patch against the current drivers/md/ sources.
#
# The compat patches are unified diffs against a snapshot of drivers/md/.
# When drivers/md/ moves, the patches drift: hunks land at large offsets or
# need fuzz, and `patch` can silently mis-target a hunk. Run this script
# after pulling a new drivers/md/ to reset every hunk to an exact,
# zero-fuzz, zero-offset apply.
#
# Each patch is re-diffed against the *cumulative* state of the patches
# that precede it in glob order, so the whole set applies in sequence with
# no fuzz and no offset. Prose preambles (text before the first `--- a/`)
# are preserved verbatim; only the diff body is regenerated.
#
# TWO classes of patch are NOT auto-regenerated, only applied to keep the
# cumulative state correct (they are hand-maintained):
#
#   * Patches with a `<name>.patch.when` guard are composition-specific — they
#     target a tree shape (meshstor-main vs bare upstream `master`) that may not
#     be the one being regenerated against. Applying them is gated on the guard;
#     regenerating them with diff(1) against the wrong shape would corrupt them.
#   * Patches with a `<name>.patch.keep` marker are deliberately authored to
#     apply to BOTH tree shapes via minimal, symmetric context (e.g. 0002),
#     which diff(1)'s default context would overwrite with shape-specific lines.
#
# Guarded by tools/testing/selftests/dkms/test_patches_apply_clean.sh —
# if that test fails for an AUTO-regenerable patch, run this script. A
# hand-maintained patch that drifts must be edited by hand (keep the context
# minimal and symmetric — see docs/maintainer.md and dkms/patches/README.md).
set -euo pipefail

REPO_ROOT="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"
cd "$REPO_ROOT"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# The union of files touched by any patch. `cp`-ed flat, mirroring the
# tarball layout that the patches target (a/md.c, not a/drivers/md/md.c).
FILES="md.c raid1.c raid10.c raid1-10.c md.h"

CUM="$WORK/cum"
mkdir -p "$CUM"
for f in $FILES; do
	[ -e "drivers/md/$f" ] && cp "drivers/md/$f" "$CUM/"
done

# patch_guard_skips PATCH -> true (0) when PATCH carries a `.when` guard that is
# NOT satisfied against $CUM. Mirrors bin/build-tarball / lib.sh.
patch_guard_skips() {
	local when="$1.when" cond neg file rx
	[ -f "$when" ] || return 1
	while IFS= read -r cond; do
		cond="${cond%%$'\r'}"
		[ -z "$cond" ] && continue
		case "$cond" in \#*) continue ;; esac
		neg=
		case "$cond" in !*) neg=1; cond="${cond#!}" ;; esac
		file="${cond%%:*}"; rx="${cond#*:}"
		if grep -Eq -- "$rx" "$CUM/$file" 2>/dev/null; then
			[ -n "$neg" ] && return 0
		else
			[ -z "$neg" ] && return 0
		fi
	done < "$when"
	return 1
}

for patch in dkms/patches/[0-9]*.patch; do
	base="$(basename "$patch")"
	pfiles="$(grep '^--- a/' "$patch" | sed 's|^--- a/||' | sort -u)"

	# Composition-specific patch whose shape doesn't match this tree: leave it
	# untouched and don't apply (it wouldn't apply here anyway).
	if patch_guard_skips "$patch"; then
		echo "skipped $base (guard not satisfied for this tree)"
		continue
	fi

	# Snapshot the cumulative state *before* this patch.
	before="$WORK/before"
	rm -rf "$before"
	mkdir -p "$before"
	for f in $FILES; do
		[ -e "$CUM/$f" ] && cp "$CUM/$f" "$before/"
	done

	# Apply the current (possibly stale) patch to the cumulative tree.
	# Fuzz/offset are tolerated here — the whole point is to absorb the
	# drift and re-emit a clean diff.
	patch -p1 -s --no-backup-if-mismatch -d "$CUM" < "$patch"

	# Hand-maintained patches: applied (above) to keep cumulative state, but
	# preserved verbatim — never re-diffed.
	if [ -f "$patch.when" ] || [ -f "$patch.keep" ]; then
		echo "preserved $base (hand-maintained: $([ -f "$patch.when" ] && echo guard )$([ -f "$patch.keep" ] && echo keep))"
		continue
	fi

	# Regenerate the diff body: per touched file, before vs after.
	body="$WORK/body"
	: > "$body"
	for f in $pfiles; do
		if diff -u --label "a/$f" --label "b/$f" \
			"$before/$f" "$CUM/$f" >> "$body"; then
			drc=0
		else
			drc=$?
		fi
		[ "$drc" -le 1 ] || {
			echo "regenerate.sh: diff error on $f (rc=$drc)" >&2
			exit 1
		}
	done

	# Preserve the prose preamble (everything before the first `--- a/`).
	preamble="$WORK/preamble"
	awk '/^--- a\//{exit} {print}' "$patch" > "$preamble"

	cat "$preamble" "$body" > "$patch"
	echo "regenerated $base [${pfiles//$'\n'/ }]"
done

echo "done — verify with: bash tools/testing/selftests/dkms/test_patches_apply_clean.sh"
