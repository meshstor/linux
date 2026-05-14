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
# Guarded by tools/testing/selftests/dkms/test_patches_apply_clean.sh —
# if that test fails, run this script.
set -euo pipefail

REPO_ROOT="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"
cd "$REPO_ROOT"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# The union of files touched by any patch. `cp`-ed flat, mirroring the
# tarball layout that the patches target (a/md.c, not a/drivers/md/md.c).
FILES="md.c raid1.c raid10.c"

CUM="$WORK/cum"
mkdir -p "$CUM"
for f in $FILES; do
	cp "drivers/md/$f" "$CUM/"
done

for patch in dkms/patches/[0-9]*.patch; do
	base="$(basename "$patch")"
	pfiles="$(grep '^--- a/' "$patch" | sed 's|^--- a/||' | sort -u)"

	# Snapshot the cumulative state *before* this patch.
	before="$WORK/before"
	rm -rf "$before"
	mkdir -p "$before"
	for f in $FILES; do
		cp "$CUM/$f" "$before/"
	done

	# Apply the current (possibly stale) patch to the cumulative tree.
	# Fuzz/offset are tolerated here — the whole point is to absorb the
	# drift and re-emit a clean diff.
	patch -p1 -s --no-backup-if-mismatch -d "$CUM" < "$patch"

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
