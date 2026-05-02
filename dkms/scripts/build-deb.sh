#!/usr/bin/env bash
# build-deb.sh — build the .deb package end-to-end.
# Must be run on a Debian/Ubuntu host (or in a debian-tooling container) — the
# RHEL/Rocky/Alma host this repo lives on cannot natively build .deb packages.
#
# 1. Build the DKMS tarball.
# 2. Stage source tree as <pkg>-<version>/ with a debian/ subdir.
# 3. Run dpkg-buildpackage -us -uc -b.
#
# Suggested invocation from a non-Debian host using a container:
#
#   podman run --rm -it -v $(pwd):/work ubuntu:24.04 bash -c '
#     apt-get update && apt-get install -y debhelper-compat dpkg-dev fakeroot
#     cd /work && dkms/scripts/build-deb.sh 0.1.0
#   '
#
# Usage: dkms/scripts/build-deb.sh <version> [<staging_dir>]
set -euo pipefail

VER="${1:?usage: $0 <version> [<staging_dir>]}"
STAGE="${2:-/tmp/debbuild}"
REPO_ROOT="$(git rev-parse --show-toplevel)"

if ! command -v dpkg-buildpackage >/dev/null 2>&1; then
    echo "ERROR: dpkg-buildpackage not found. Run on a Debian/Ubuntu host or container." >&2
    echo "       See the comment block at the top of $0 for a podman invocation." >&2
    exit 1
fi

cd "$REPO_ROOT"
"$REPO_ROOT/dkms/scripts/build-tarball.sh" "$VER"

# Stage <pkg>-<version>/ with debian/ inside.
rm -rf "$STAGE"
mkdir -p "$STAGE"
cp "$REPO_ROOT/build/meshstor-ms-${VER}.dkms.tar.gz" "$STAGE/"
cd "$STAGE"
tar xzf "meshstor-ms-${VER}.dkms.tar.gz"
PKGDIR="$STAGE/meshstor-ms-${VER}"
cp -r "$REPO_ROOT/dkms/debian" "$PKGDIR/debian"

# Substitute #MODULE_VERSION# in debian/* templates.
find "$PKGDIR/debian" -type f -exec sed -i "s/#MODULE_VERSION#/${VER}/g" {} \;

cd "$PKGDIR"
dpkg-buildpackage -us -uc -b

echo
echo "=== Output ==="
ls -la "$STAGE/meshstor-ms-dkms_${VER}"*.deb 2>/dev/null
