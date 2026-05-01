#!/usr/bin/env bash
# Assemble a DKMS tarball from drivers/md/ + dkms/
# Usage: dkms/scripts/build-tarball.sh <version>
set -euo pipefail

VER="${1:?usage: $0 <version>}"
REPO_ROOT="$(git rev-parse --show-toplevel)"
OUT="$REPO_ROOT/build/meshstor-md-$VER"

cd "$REPO_ROOT"
rm -rf "$OUT"
mkdir -p "$OUT"

# Copy kernel sources per manifest (one file per line, supports globs)
while IFS= read -r entry; do
    [ -z "$entry" ] && continue
    [[ "$entry" =~ ^# ]] && continue
    cp drivers/md/$entry "$OUT/"
done < dkms/manifest.txt

# Copy compat layer
cp -r dkms/compat "$OUT/"

# Render templates with version substituted
sed "s/@VERSION@/$VER/g" dkms/dkms.conf.in > "$OUT/dkms.conf"
sed "s/@VERSION@/$VER/g" dkms/Makefile.in  > "$OUT/Makefile"

# License
cp dkms/COPYING "$OUT/"

# Tarball
cd "$REPO_ROOT/build"
tar czf "meshstor-md-$VER.dkms.tar.gz" "meshstor-md-$VER/"

echo "Built: $REPO_ROOT/build/meshstor-md-$VER.dkms.tar.gz"
