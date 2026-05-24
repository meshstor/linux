# Build & release engineering

How the meshstor-ms DKMS package is assembled, signed, and released.
Reference for the maintainer doing a release.

For the underlying source layout (why `drivers/md/` is upstream-canonical
and `dkms/` is ours alone) see [architecture.md](architecture.md).
For adding compat shims and rebasing on upstream Linux see
[maintainer.md](maintainer.md).

## Tarball pipeline

The package source artifact is a single tarball, `meshstor-ms-<VER>.dkms.tar.gz`,
produced by [`bin/build-tarball`](../bin/build-tarball).
The tarball contains a flat directory of post-rename `.c`/`.h` files plus
the compat layer, the templated `dkms.conf` and `Makefile`, and the
`COPYING` license. Both `.rpm` and `.deb` packagers consume this same
tarball.

The pipeline:

| Step | What it does | Source |
|---|---|---|
| 1. Copy manifest sources | Per-line entries in `dkms/manifest.txt` are copied from `drivers/md/` into the staging directory. | `bin/build-tarball:23-27` |
| 2. Copy compat layer | `dkms/compat/` (containing `compat.h`) into the staging directory. | `bin/build-tarball:30` |
| 3. Stub feature_flags.h | A no-op header is dropped in. The real one is generated at module-build time on the customer host (so it matches the *running* kernel, not whichever kernel produced the tarball). | `bin/build-tarball:39-46` |
| 4. Apply pre-rename patches | Each `dkms/patches/NNNN-*.patch` applied in glob-sorted order. These touch upstream-named identifiers, so they must run before step 5. | `bin/build-tarball:54-58` |
| 5. Rename pass | `sed` rules from `dkms/rename.sed` (plus auto-generated UAPI keep-list) translate `md_*` → `ms_*`, `MD_*` → `MS_*`, `mddev` → `mssev` across every `.c` and `.h`. | `bin/build-tarball:60-89` |
| 6. Rename source filenames | `md.c` → `ms.c`, `raid1.c` → `raid1_ms.c`, etc. | `bin/build-tarball:91-100` |
| 7. Inject `extern int ms_major` | One-time bridge: the rename produces a `ms_major` reference but no extern declaration, so we add one to `ms.h`. | `bin/build-tarball:104-114` |
| 8. Render templates | `dkms.conf.in` and `Makefile.in` get the `@VERSION@` token substituted. | `bin/build-tarball:117-119` |
| 9. Tar | `tar czf build/meshstor-ms-<VER>.dkms.tar.gz`. | `bin/build-tarball:124-126` |

Run it directly:

```bash
bin/build-tarball 0.1.0
# ...
# Built: /home/mykola/sync/linux-meshstor/build/meshstor-ms-0.1.0.dkms.tar.gz
```

The produced tree under `build/meshstor-ms-0.1.0/`:

```
ms.c, ms.h, ms-bitmap.c, ms-bitmap.h, ms-llbitmap.c, ms-cluster.h
raid0.h, raid1_ms.c, raid1_ms.h, raid10_ms.c, raid10_ms.h, raid1-10_ms.c
compat/compat.h, compat/feature_flags.h
dkms.conf, Makefile, COPYING
```

(Note `raid0.h` is included to satisfy includes from raid1/10 personalities,
but no `raid0_ms.c` ships — RAID0 is out of scope per [compat.md](compat.md#out-of-scope).)

## rpm packaging

[`bin/build-rpm`](../bin/build-rpm) calls
`bin/build-tarball`, then renders the spec template, then runs
`rpmbuild -bb`. Output is a `noarch` source-DKMS rpm.

```bash
bin/build-rpm 0.1.0 build/rpmbuild
# ...
# Wrote: build/rpmbuild/RPMS/noarch/meshstor-ms-dkms-0.1.0-1.el10.noarch.rpm
```

The `dist` tag in the filename (e.g., `.el10`) is purely cosmetic — it
controls only the rpm's filename suffix and `Vendor`/`Distribution`
metadata, not the contents. A noarch DKMS source package built on RHEL 10
installs cleanly on RHEL 9 and on Rocky 9/10 with `rpm -i --force` (or
with the `dist` left unset). For repository hygiene, build per-distro
rpms by setting `--define "dist .elN"`:

```bash
rpmbuild --define "_topdir build/rpmbuild" \
         --define "dist .el9" \
         -bb build/rpmbuild/SPECS/meshstor-ms-dkms.spec
```

The spec template lives at
[`dkms/rpm/meshstor-ms-dkms.spec.in`](../dkms/rpm/meshstor-ms-dkms.spec.in).
The render step substitutes `@VERSION@` and `@CHANGELOG_DATE@`.

## deb packaging

Two paths, depending on whether the build host is Debian/Ubuntu native
or non-Debian:

### `bin/build-deb` — native Debian/Ubuntu

[`bin/build-deb`](../bin/build-deb) uses the
canonical `dpkg-buildpackage -us -uc -b` flow. Run on a Debian/Ubuntu
host that has `debhelper`, `dpkg-dev`, and `fakeroot` installed.

```bash
bin/build-deb 0.1.0 build/debbuild
# Output: build/debbuild/meshstor-ms-dkms_0.1.0-1_all.deb
```

For CI from a non-Debian build server, run it inside a container:

```bash
podman run --rm -it -v "$PWD:/work" ubuntu:24.04 bash -c '
    apt-get update
    apt-get install -y debhelper-compat dpkg-dev fakeroot
    cd /work && bin/build-deb 0.1.0
'
```

### `bin/build-deb-direct` — cross-build from RHEL

[`bin/build-deb-direct`](../bin/build-deb-direct)
uses `dpkg-deb` directly, hand-writing the control fields and DKMS
postinst/prerm scripts. Bypasses `debhelper` entirely. Used when the
build server is RHEL/Rocky/Alma and we don't want a container hop.

```bash
# RHEL host, with EPEL's dpkg installed:
sudo dnf install -y dpkg
bin/build-deb-direct 0.1.0 build/debdirect
# Output: build/debdirect/meshstor-ms-dkms_0.1.0-1_all.deb
```

The output is byte-equivalent in structure to the native-built deb;
verify with `dpkg-deb --info`. The trade-off: no debhelper magic, so
any future changes to `debian/control` field semantics need manual
updates in this script.

## Signing infrastructure

Three signing paths, in increasing order of operational cleanliness:

### DKMS auto-MOK (default)

DKMS generates a per-host MOK keypair the first time it builds a
module on a Secure Boot-enabled host (typically at
`/var/lib/dkms/mok.key` and `/var/lib/dkms/mok.pub`). Every rebuilt
module gets signed with that local key. Customer enrolls the public
half once via `mokutil --import`.

Pros:

- Zero CI infrastructure on our side.
- Works with the stock DKMS package on every supported distro.

Cons:

- Per-host fingerprint — every customer's host has a different signing
  key, no fleet-wide trust model.
- Customer can't verify the modules were actually built from our source
  (only that DKMS built them).

This is what [install.md](install.md#path-1-dkms-rebuild--auto-mok-default)
("Path 1") describes. Recommended only when the alternative is unavailable.

### Vendor key (recommended for production)

We generate a long-lived keypair once at build-infrastructure setup
time. This is plain `openssl` (kept inline rather than wrapped in a
helper script):

```bash
OUT=/vault/meshstor-keys
mkdir -p "$OUT"
# Private key + self-signed PEM cert, 10-year validity.
openssl req -new -x509 -newkey rsa:4096 -nodes \
    -keyout "$OUT/meshstor-vendor.priv" \
    -outform PEM -out "$OUT/meshstor-vendor.pem" \
    -days 3650 \
    -subj "/CN=meshstor-ms vendor signing key/O=Meshstor/"
# DER form is what the customer enrolls via mokutil.
openssl x509 -in "$OUT/meshstor-vendor.pem" \
    -outform DER -out "$OUT/meshstor-vendor.der"
chmod 400 "$OUT/meshstor-vendor.priv"
# Produces:
#   meshstor-vendor.priv  — KEEP SECRET, build-server only
#   meshstor-vendor.pem   — internal use (signing operations)
#   meshstor-vendor.der   — ships to customers in meshstor-ms-keys package
```

The build pipeline signs every released `.ko` file with the private
key:

```bash
/lib/modules/$KVER/build/scripts/sign-file sha256 \
    /vault/meshstor-keys/meshstor-vendor.priv \
    /vault/meshstor-keys/meshstor-vendor.pem \
    module.ko
```

Customer enrolls the public key (`meshstor-vendor.der`) once per host
via `mokutil --import`. Modules then load on every customer host without
DKMS rebuild and without per-host signing.

Pros:

- Fleet-wide trust: one enrolled key serves every meshstor-ms release
  on every kernel version on every host in the fleet.
- Faster install (no per-host build step).
- Modules are byte-identical across the fleet — easier to audit.

Cons:

- Vendor private key needs custody (offline build server, HSM, or
  similar).
- Per (kernel × distro) tuple needs a signed prebuilt — more CI matrix.

The pre-built distribution package is documented in
[install.md](install.md#path-2-vendor-pre-signed-modules-private-repo-customers).

### Test-mode unsigned

Secure Boot off. No signing. Modules load directly. Diagnostic
fallback only — see
[install.md](install.md#path-3-secure-boot-disabled-testdev-only).

## Release flow

Step-by-step for cutting version `X.Y.Z`:

```bash
# 1. Confirm tree is clean and on meshstor-main.
git status
git checkout meshstor-main
git log --oneline -1
```

```bash
# 2. Update debian/changelog with the new version stanza.
$EDITOR dkms/debian/changelog
# Add a stanza at the top:
#   meshstor-ms-dkms (X.Y.Z-1) unstable; urgency=medium
#
#     * <user-facing change summary>
#
#    -- Meshstor <support@example.com>  <RFC 822 date>
git add dkms/debian/changelog
git -c commit.gpgsign=false commit -m "release: bump to X.Y.Z"
```

(`dkms/dkms.conf.in` and `dkms/rpm/meshstor-ms-dkms.spec.in` use
`@VERSION@` templates substituted at build time, so there's no version
line to bump in those files.)

```bash
# 3. Build the rpm. Verify clean build.
bin/build-rpm X.Y.Z /tmp/release-rpm
ls -la /tmp/release-rpm/RPMS/noarch/
# Expected: meshstor-ms-dkms-X.Y.Z-1.el10.noarch.rpm
```

```bash
# 4. Build the deb (cross-build from RHEL OK):
bin/build-deb-direct X.Y.Z /tmp/release-deb
ls -la /tmp/release-deb/
# Expected: meshstor-ms-dkms_X.Y.Z-1_all.deb
```

```bash
# 5. Smoke-test on the RHEL 10 baremetal host.
scp /tmp/release-rpm/RPMS/noarch/meshstor-ms-dkms-X.Y.Z-*.rpm \
    mykola@192.168.200.32:/tmp/
ssh mykola@192.168.200.32 'sudo rpm -e meshstor-ms-dkms 2>/dev/null
    sudo rpm -i /tmp/meshstor-ms-dkms-X.Y.Z-*.rpm
    sudo modprobe ms_mod raid1_ms raid10_ms
    cat /proc/msstat
    sudo dkms status meshstor-ms'
# Expected: package installs, modules load, /proc/msstat shows
#   "Personalities : [raid1] [raid10]", dkms status reports installed
```

```bash
# 6. Tag and push.
git tag -a "vX.Y.Z" -m "meshstor-ms X.Y.Z"
git push origin meshstor-main
git push origin "vX.Y.Z"
```

```bash
# 7. (Vendor-signed releases only) Sign the prebuilt .ko files
#    and produce the meshstor-ms-prebuilt-X.Y.Z package per kernel × distro tuple.
#    This step depends on your CI's signing-server setup; out of scope for this doc.
```

```bash
# 8. Publish to the customer-facing repo.
#    rpms → createrepo_c on a yum-style repo
#    debs → apt-ftparchive or reprepro on an apt-style repo
#    Out of scope for this doc — depends on hosting choice.
```

After step 8, customers running the [install.md](install.md) recipes
get the new version on their next `dnf update` / `apt update`.

## Troubleshooting the build

If `bin/build-tarball` fails, the most common cause is a kernel header
path missing or different. Run with the `KDIR` variable pointing at the
intended target kernel's headers:

```bash
KDIR=/path/to/kernel-headers \
    bin/build-tarball X.Y.Z
```

If `bin/build-rpm` fails inside `rpmbuild`, look at the rpmbuild log
under `build/rpmbuild/BUILD/` and `build/rpmbuild/BUILDROOT/`. The
typical issue is a missing build-time dependency on the build host
(`rpm-build`, `kernel-headers`).

If `bin/build-deb-direct` fails, the typical issue is `dpkg-deb` not in
`PATH` on the RHEL host — install `dpkg` from EPEL.

For rebase-related build failures (upstream changed an identifier
the rename pass references), see
[maintainer.md](maintainer.md#upstream-rebase-workflow).

## See also

- [install.md](install.md) — how customers consume the released package
- [architecture.md](architecture.md) — why the rename pass exists
- [maintainer.md](maintainer.md) — adding compat shims, upstream rebase
- [compat.md](compat.md) — supported distros and kernels (build matrix)
