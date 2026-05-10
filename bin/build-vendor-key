#!/usr/bin/env bash
# build-vendor-key.sh — generate the meshstor vendor signing key pair.
# Run ONCE at vendor-infrastructure setup time. Private key stays on the
# build server; public key (.der) ships in the meshstor-ms-keys package
# for customers to enroll via mokutil.
#
# Output:
#   vendor-keys/meshstor-vendor.priv   — KEEP SECRET, build-server only
#   vendor-keys/meshstor-vendor.pem    — internal use
#   vendor-keys/meshstor-vendor.der    — ships to customers

set -euo pipefail

OUT=${1:-vendor-keys}
mkdir -p "$OUT"
if [ -f "$OUT/meshstor-vendor.priv" ]; then
    echo "ERROR: $OUT/meshstor-vendor.priv already exists. Refusing to overwrite."
    echo "Move or delete the existing key first if you intentionally want a new one."
    exit 1
fi

echo "Generating meshstor vendor key pair in $OUT/ ..."
openssl req -new -x509 \
    -newkey rsa:4096 \
    -keyout "$OUT/meshstor-vendor.priv" \
    -outform PEM -out "$OUT/meshstor-vendor.pem" \
    -days 3650 -nodes \
    -subj "/CN=meshstor-ms vendor signing key/O=Meshstor/"

openssl x509 -in "$OUT/meshstor-vendor.pem" -outform DER -out "$OUT/meshstor-vendor.der"

chmod 400 "$OUT/meshstor-vendor.priv"
chmod 644 "$OUT/meshstor-vendor.pem" "$OUT/meshstor-vendor.der"

echo
echo "Done. Files:"
ls -la "$OUT/meshstor-vendor."*
echo
echo "  meshstor-vendor.priv  — KEEP SECRET on build server only. Do not commit."
echo "  meshstor-vendor.pem   — internal use, signing operations."
echo "  meshstor-vendor.der   — ships to customers in meshstor-ms-keys package."
echo
echo "To sign a module:"
echo "  /lib/modules/\$KVER/build/scripts/sign-file sha256 \\"
echo "      $OUT/meshstor-vendor.priv $OUT/meshstor-vendor.pem module.ko"
