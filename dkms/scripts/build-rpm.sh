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
REPO_ROOT="$(git rev-parse --show-toplevel)"
TOPDIR="${2:-$REPO_ROOT/build/rpmbuild}"

cd "$REPO_ROOT"

# 1. Build the DKMS tarball.
"$REPO_ROOT/dkms/scripts/build-tarball.sh" "$VER"

# 2. Stage rpmbuild tree.
mkdir -p "$TOPDIR"/{SOURCES,SPECS,BUILD,BUILDROOT,RPMS,SRPMS}
cp "$REPO_ROOT/build/meshstor-ms-${VER}.dkms.tar.gz" "$TOPDIR/SOURCES/"

# 3. Render spec.
sed -e "s/@VERSION@/$VER/g" \
    -e "s/@CHANGELOG_DATE@/$(LC_ALL=C date '+%a %b %d %Y')/" \
    "$REPO_ROOT/dkms/rpm/meshstor-ms-dkms.spec.in" \
    > "$TOPDIR/SPECS/meshstor-ms-dkms.spec"

# 4. Build.
rpmbuild --define "_topdir $TOPDIR" -bb "$TOPDIR/SPECS/meshstor-ms-dkms.spec"

echo
echo "=== Output ==="
find "$TOPDIR/RPMS" -name "meshstor-ms-dkms-${VER}-*.rpm" -exec ls -la {} \;
