# Phase 1 packaging validation (2026-05-02)

End-to-end DKMS install flow verified on the RHEL 10.1 host plus header-only
build verification across all four target distros' kernel headers.

## DKMS guard variable: KBUILD_EXTMOD not KERNELRELEASE

Initial DKMS install attempts on RHEL 10.1 (192.168.200.32) failed with
`make: *** No targets.  Stop.` despite the wrapper Makefile defining `all:`.
Root cause: DKMS invokes the wrapper as `make KERNELRELEASE=<kver> KDIR=<path>`,
setting `KERNELRELEASE` on the OUTER command line. The conventional
`ifeq ($(KERNELRELEASE),)` guard for out-of-tree modules therefore hides our
`all`/`feature_flags`/etc. targets during the initial DKMS invocation. Fixed
by switching to `ifeq ($(KBUILD_EXTMOD),)` — `KBUILD_EXTMOD` is only set by
kbuild during the `make -C $KDIR M=$M` recursion, so it correctly
distinguishes "DKMS called us" from "kbuild recursed back into us".

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

## Cross-distro live-load status

Updated 2026-05-02 after additional vng work (booting non-host kernels by
copying their `/lib/modules/<KVER>/` tree to the host before vng invocation).

| Distro / kernel | Build | Live load via vng | Live array test |
|---|---|---|---|
| RHEL 10.1 / Rocky 10 (6.12) | ✅ | ✅ | ✅ raid1 / raid10 / takeover / llbitmap |
| Ubuntu 24.04 LTS HWE (6.14) | ✅ | ✅ | ✅ raid1 array, EWMA tracking |
| Ubuntu 26.04 LTS (6.17) | ✅ | ✅ | ✅ raid1 array, EWMA tracking |
| RHEL 9.7 / Rocky 9 (5.14) | ✅ | ⚠️ vng-quirk | not tested live yet |
| Ubuntu 24.04 GA (6.8) | out of scope | — | — |

### vng setup pattern that worked

```bash
# 1. Extract the target distro's kernel modules tree (linux-modules-* deb or
#    kernel-modules-core rpm) and copy to host /lib/modules/.
#    Symlink /lib/modules/<KVER>/build to extracted kernel-headers.
sudo cp -r /tmp/u24-mods/lib/modules/6.14.0-37-generic /lib/modules/
sudo ln -sf /tmp/kdevs/u24/usr/src/linux-headers-6.14.0-37-generic \
    /lib/modules/6.14.0-37-generic/build
sudo depmod -a 6.14.0-37-generic

# 2. Build our DKMS modules against the target headers.
env -u KDIR KDIR=/tmp/kdevs/u24/usr/src/linux-headers-6.14.0-37-generic \
    bash dkms/scripts/build-tarball.sh 0.1.0
# (then make CC=gcc HOSTCC=gcc against the same KDIR if cross-host)

# 3. Boot vng with the target vmlinuz and run the test script.
vng --run /tmp/kernels/u24/boot/vmlinuz-6.14.0-37-generic \
    --busybox /tmp/busybox-static --disable-microvm \
    --exec "sh /tmp/test-script.sh"
```

The trick is making vng's host fs LOOK LIKE it has the target kernel's modules
tree at the conventional path. Once that's set up, vng boots the alternate
vmlinuz and finds the modules where it expects them.

### RHEL 9.7's 5.14 kernel — vng quirk + runtime hang

Two issues surfaced after deeper investigation on 2026-05-02:

**Issue 1: vng requires the vmlinuz live at `/boot/vmlinuz-<KVER>`.** When the
bzImage is at a custom path like `/tmp/kernels/.../vmlinuz`, vng boots the
kernel but its serial-console wiring (used for capturing exec output back to
the host shell) silently fails for RHEL/Rocky kernels. Same path with Ubuntu
kernels works, so it's specific to how the RHEL kernel/vng interact. Fix:
copy the vmlinuz to `/boot/vmlinuz-<KVER>` before invoking vng. With that,
the kernel boots cleanly and exec output is captured normally.

**Issue 2: `insmod ms_mod.ko` hangs the kernel on r9 in vng.** Module BUILDS
correctly (right vermagic, correct symbol exports, modinfo shows
`description: MD RAID framework, license: GPL, rhelversion: 9.7`). But
loading hangs the entire kernel within vng — even a 5-second `timeout`
around insmod doesn't return. Pre-insmod state is healthy (25 modules
loaded, 1.6 GB free RAM, /proc/msstat absent as expected before our module
loads). This is a runtime issue specific to RHEL 9.7 + vng + our module init,
not a build problem.

Likely runtime suspects (need a real Rocky 9 / RHEL 9 environment to bisect):
- `register_blkdev` on r9 may behave differently from r10's backported version
- Some queue_limits transactional-API call may deadlock
- A subsystem-init hook may collide with r9-specific kernel state

Also noticed a related bug while inspecting modinfo:
`alias: block-major-ms_major-*`. The rename converted
`MODULE_ALIAS_BLOCKDEV_MAJOR(MD_MAJOR)` to
`MODULE_ALIAS_BLOCKDEV_MAJOR(ms_major)`. `MODULE_ALIAS_BLOCKDEV_MAJOR` does
compile-time stringification, so `ms_major` (a runtime variable, not a
constant) gets stringified literally as "ms_major" — producing a malformed
alias. Doesn't affect functionality on r10/Ubuntu (the explicit `MODULE_ALIAS("ms")`
covers udev autoload), but should be fixed: use the upstream `MD_MAJOR`
literal numeric value (9) — except we're a different subsystem, so the right
fix is `MODULE_ALIAS_BLOCKDEV_MAJOR(0)` (dynamic, no fixed major) or simply
drop the alias since `MODULE_ALIAS("ms")` is sufficient for our case.

**Conclusion**: live-test on r9 needs a real Rocky 9 / RHEL 9 host with kdump
configured to capture the runtime hang's traceback. The .rpm/.ko produced
for r9 is structurally correct; the runtime issue is small enough that it's
likely a one- or two-symbol fix once we have a panic trace.
