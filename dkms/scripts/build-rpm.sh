#!/usr/bin/env bash
# build-rpm.sh — build the .rpm package end-to-end.
# 1. Build the DKMS tarball (which uses target-kernel feature detection).
# 2. Stage the tarball into rpmbuild/SOURCES.
# 3. Render the spec template with VERSION + CHANGELOG_DATE substituted.
# 4. Run rpmbuild -bb.
#
# Usage: dkms/scripts/build-rpm.sh <version> [<rpmbuild_topdir>]
# Default rpmbuild topdir: build/rpmbuild
set -euo pipefail

VER="${1:?usage: $0 <version> [<rpmbuild_topdir>]}"
# RPM's `Version:` tag forbids '-' (it is the Version-Release separator).
# Translate it to '~' for that field only — the rest of the pipeline (tarball
# name, unpacked dir, DKMS module version) keeps the original dashed form,
# which is what the project's perf-variant naming and DKMS expect.
RPM_VER="${VER//-/\~}"  # backslash suppresses bash tilde expansion in replacement
REPO_ROOT="$(git rev-parse --show-toplevel)"
# rpmbuild requires an absolute `_topdir` — a relative path gets interpreted
# from rpmbuild's CWD as `/<topdir>`, which then doesn't exist.
TOPDIR="$(realpath -m "${2:-$REPO_ROOT/build/rpmbuild}")"

cd "$REPO_ROOT"

# 1. Build the DKMS tarball.
"$REPO_ROOT/dkms/scripts/build-tarball.sh" "$VER"

# 2. Stage rpmbuild tree.
mkdir -p "$TOPDIR"/{SOURCES,SPECS,BUILD,BUILDROOT,RPMS,SRPMS}
cp "$REPO_ROOT/build/meshstor-ms-${VER}.dkms.tar.gz" "$TOPDIR/SOURCES/"

# 3. Render spec.
sed -e "s/@VERSION@/$RPM_VER/g" \
    -e "s/@MODULE_VERSION@/$VER/g" \
    -e "s/@CHANGELOG_DATE@/$(LC_ALL=C date '+%a %b %d %Y')/" \
    "$REPO_ROOT/dkms/rpm/meshstor-ms-dkms.spec.in" \
    > "$TOPDIR/SPECS/meshstor-ms-dkms.spec"

# 4. Build.
rpmbuild --define "_topdir $TOPDIR" -bb "$TOPDIR/SPECS/meshstor-ms-dkms.spec"

echo
echo "=== Output ==="
find "$TOPDIR/RPMS" -name "meshstor-ms-dkms-${RPM_VER}-*.rpm" -exec ls -la {} \;
