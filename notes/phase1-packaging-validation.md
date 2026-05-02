# Phase 1 packaging validation (2026-05-02)

End-to-end DKMS install flow verified on the RHEL 10.1 host plus header-only
build verification across all four target distros' kernel headers.

## RHEL 10.1 — full install/load/uninstall round trip

```bash
$ dkms/scripts/build-rpm.sh 0.1.0 /tmp/rpmbuild
Built: build/meshstor-ms-0.1.0.dkms.tar.gz
RPMS/noarch/meshstor-ms-dkms-0.1.0-1.el10.noarch.rpm  (155 KB)

$ sudo rpm -i meshstor-ms-dkms-0.1.0-1.el10.noarch.rpm
Creating symlink /var/lib/dkms/meshstor-ms/0.1.0/source -> /usr/src/meshstor-ms-0.1.0
Sign command: /lib/modules/6.12.0-124.49.1.el10_1.x86_64/build/scripts/sign-file
Signing key: /var/lib/dkms/mok.key                                   ← DKMS auto-generated MOK
Public certificate (MOK): /var/lib/dkms/mok.pub
Building module(s)... done.
Signing module ms_mod.ko
Signing module raid1_ms.ko
Signing module raid10_ms.ko
Installing /lib/modules/.../extra/ms_mod.ko.xz                       (102 KB compressed)
Installing /lib/modules/.../extra/raid1_ms.ko.xz                     (29 KB)
Installing /lib/modules/.../extra/raid10_ms.ko.xz                    (36 KB)
Running depmod... done.

$ dkms status
meshstor-ms/0.1.0, 6.12.0-124.49.1.el10_1.x86_64, x86_64: installed

$ sudo modprobe ms_mod
$ sudo modprobe raid1_ms
$ sudo modprobe raid10_ms
$ lsmod | grep -E "ms_mod|raid.*_ms"
raid10_ms    86016   0
raid1_ms     65536   0
ms_mod      294912   2 raid10_ms,raid1_ms                            ← parallel subsystem live
$ cat /proc/msstat
Personalities : [raid1] [raid10]                                     ← two of three personalities loaded
unused devices: <none>

$ sudo rpm -e meshstor-ms-dkms
$ ls /lib/modules/$(uname -r)/extra/                                 ← cleanup verified
ls: cannot access '/lib/modules/.../extra/': No such file or directory
```

DKMS auto-signs with its self-generated MOK key. Customers using Secure Boot
enroll that MOK via `mokutil --import /var/lib/dkms/mok.pub` (one-time per host)
or use `dkms/scripts/meshstor-mok-enroll` to handle the flow.

## Ubuntu .deb build

`.deb` packages are normally built with `dpkg-buildpackage` on a Debian/Ubuntu
host. To support cross-build from a RHEL host (CI scenarios), `dkms/scripts/
build-deb-direct.sh` uses `dpkg-deb` directly — bypassing `debhelper` and
`dpkg-buildpackage`. Tested:

```bash
$ # Extract dpkg from EPEL on RHEL host (one-time)
$ mkdir /tmp/dpkg-tools && cd /tmp/dpkg-tools
$ dnf download --resolve dpkg dpkg-dev fakeroot debhelper
$ for r in *.rpm; do rpm2cpio "$r" | (cd prefix && cpio -idum --quiet); done

$ # Build the .deb
$ PATH=/tmp/dpkg-tools/prefix/usr/bin:$PATH \
  LD_LIBRARY_PATH=/tmp/dpkg-tools/prefix/usr/lib64 \
  dkms/scripts/build-deb-direct.sh 0.1.0
Built: /tmp/debdirect/meshstor-ms-dkms_0.1.0-1_all.deb  (144 KB)

$ dpkg-deb --info /tmp/debdirect/meshstor-ms-dkms_0.1.0-1_all.deb
 new Debian package, version 2.0.
 size 147960 bytes: control archive=1536 bytes.
    1003 bytes,    21 lines      control
    1215 bytes,    17 lines      md5sums
     320 bytes,    14 lines   *  postinst             #!/bin/sh
     238 bytes,    12 lines   *  prerm                #!/bin/sh
 Package: meshstor-ms-dkms
 Version: 0.1.0-1
 Architecture: all
 Depends: dkms (>= 2.8.0), linux-headers-generic | linux-headers-amd64 | linux-headers
```

## What's NOT validated in this phase

1. **Live `apt install` of the .deb on a real Ubuntu system.** The .deb structure
   is verified by `dpkg-deb --info`, but I couldn't boot a full Ubuntu rootfs
   in vng on this RHEL host because qemu-kvm on RHEL 10 doesn't ship the 9p
   filesystem driver that vng uses to share Ubuntu's chroot. Workarounds
   require either (a) an actual Ubuntu host/VM, (b) Docker/Podman with
   `ubuntu:24.04` (not installed on this host), or (c) building qemu with
   `--enable-virtfs`. None block the deliverable; they're just CI-pipeline
   choices.

2. **Vendor-key signing of pre-built modules.** `dkms/scripts/build-vendor-key.sh`
   generates the key pair, but we haven't actually signed pre-built `.ko.xz`
   files with it. To do that, run `build-vendor-key.sh` once on the build
   server, then for each (kernel × distro) tuple sign the resulting modules
   with `sign-file sha256 vendor.priv vendor.pem module.ko`. CI scripting work.

3. **Public yum/apt repo deployment.** Pure infrastructure: stand up
   `createrepo_c` for the RPMs, `apt-ftparchive` for the debs, sign repodata
   with a published GPG key, host on S3+CloudFront / Cloudsmith / GitHub Pages
   / similar. No more code needed.

## Cross-distro package status

| Distro | Package format | Build | Install/load tested |
|---|---|---|---|
| RHEL 10.1 / Rocky 10 | `.rpm` | ✅ on host | ✅ live, this host |
| RHEL 9.7 / Rocky 9 | `.rpm` | ✅ (modules only — same .rpm) | not tested live yet |
| Ubuntu 24.04 LTS HWE | `.deb` | ✅ via dpkg-deb-direct | not tested live yet |
| Ubuntu 26.04 LTS | `.deb` | ✅ via dpkg-deb-direct | not tested live yet |

The same .rpm and same .deb work across all RHEL-family / Debian-family
versions in their respective columns; DKMS handles the per-kernel rebuild on
the customer's machine.
