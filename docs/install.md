# Installation

End-user install recipes for `meshstor-ms-dkms` on RHEL 9.x, RHEL 10.x,
Ubuntu 24.04 LTS HWE, and Ubuntu 26.04 LTS. This page covers three
signing paths in order of expected customer prevalence.

For the architecture rationale (why this is a parallel `ms_*` subsystem
rather than a kernel-md replacement) see [architecture.md](architecture.md).
For day-to-day operation after install see [admin.md](admin.md). For the
supported kernel matrix and per-distro caveats see [compat.md](compat.md).

## Prerequisites

DKMS rebuilds the modules against the running kernel on each install
and on every kernel upgrade. The customer host needs DKMS, the kernel's
header package, and (for Secure Boot hosts) `mokutil`.

### RHEL 9.x / 10.x / Rocky 9 / Rocky 10

```bash
sudo dnf install -y \
    dkms \
    "kernel-devel-$(uname -r)" \
    "kernel-headers-$(uname -r)" \
    mokutil
```

### Ubuntu 24.04 HWE / Ubuntu 26.04

```bash
sudo apt update
sudo apt install -y \
    dkms \
    "linux-headers-$(uname -r)" \
    mokutil
```

If your system runs in legacy BIOS mode (no `/sys/firmware/efi/`),
skip `mokutil`; signing is irrelevant without Secure Boot.

## Path 1 — DKMS rebuild + auto-MOK (default)

This is the default path that DKMS uses when a customer installs the
package. The first install on each host generates a per-host MOK key,
signs the rebuilt modules with it, and prompts the customer to enroll
the public key once via `mokutil`. Subsequent kernel upgrades reuse
the same key and rebuild silently.

### RHEL 9.x / 10.x / Rocky 9 / Rocky 10

```bash
# 1. Install the .rpm. DKMS auto-rebuilds + signs.
sudo dnf install -y ./meshstor-ms-dkms-0.1.0-1.el10.noarch.rpm
```

Expected output (excerpted):

```
Sign command: /lib/modules/.../build/scripts/sign-file
Signing key: /var/lib/dkms/mok.key
Public certificate (MOK): /var/lib/dkms/mok.pub
Building module(s)... done.
Signing module ms_mod.ko
Signing module raid1_ms.ko
Signing module raid10_ms.ko
Installing /lib/modules/.../extra/ms_mod.ko.xz
Installing /lib/modules/.../extra/raid1_ms.ko.xz
Installing /lib/modules/.../extra/raid10_ms.ko.xz
```

```bash
# 2. Confirm Secure Boot state. If OFF, skip to step 4.
mokutil --sb-state
# SecureBoot enabled  → continue with step 3
# SecureBoot disabled → skip to step 4
```

```bash
# 3. (Secure Boot hosts only) Enroll the DKMS-generated public key.
sudo mokutil --import /var/lib/dkms/mok.pub
# You will be prompted to set a one-time password. Remember it.

# 4. Reboot. At the blue MokManager screen:
#      Enroll MOK → Continue → Yes → enter the one-time password → Reboot
sudo reboot
```

```bash
# 5. After reboot, verify the modules load and the subsystem is live.
sudo modprobe ms_mod raid1_ms raid10_ms
lsmod | grep -E '^ms_mod|^raid1_ms|^raid10_ms'
cat /proc/msstat
```

Expected:

```
raid10_ms              86016  0
raid1_ms               65536  0
ms_mod                294912  2 raid10_ms,raid1_ms
Personalities : [raid1] [raid10]
unused devices: <none>
```

### Ubuntu 24.04 HWE / Ubuntu 26.04

```bash
# 1. Install the .deb. DKMS auto-rebuilds + signs.
sudo apt install -y ./meshstor-ms-dkms_0.1.0-1_all.deb
```

On Ubuntu, DKMS reuses the system MOK key at
`/var/lib/shim-signed/mok/` if present (set up by `update-secureboot-policy`
or `mokutil --import`). On a fresh host that doesn't have a system MOK
yet, run:

```bash
# Set up Ubuntu's system MOK key (one-time per host).
sudo dpkg-reconfigure shim-signed
# Follow the prompts to generate a MOK key and prepare it for enrollment.
sudo update-secureboot-policy --new-key
sudo update-secureboot-policy --enroll-key
sudo reboot
# Complete enrollment in MokManager at boot.
```

```bash
# 2. After reboot, verify.
sudo modprobe ms_mod raid1_ms raid10_ms
lsmod | grep -E '^ms_mod|^raid1_ms|^raid10_ms'
cat /proc/msstat
```

Same expected output as the RHEL path.

## Path 2 — Vendor pre-signed modules (private repo customers)

Customers receiving modules signed with the meshstor vendor key (rather
than per-host DKMS keys) can skip the DKMS rebuild and use pre-built
`.ko` files. This is the recommended production path: modules deploy
identically across the fleet and a single key enrollment per host
serves every future release.

The flow assumes the customer has already received the vendor public
key (`meshstor-vendor.der`) — typically delivered via a separate
`meshstor-ms-keys` package or out-of-band download.

### RHEL 9.x / 10.x / Rocky 9 / Rocky 10

```bash
# 1. Confirm Secure Boot state.
mokutil --sb-state
# Continue with step 2 only if "SecureBoot enabled". On disabled hosts,
# the .ko files load directly without enrollment.

# 2. Enroll the meshstor vendor public key (one-time per host).
sudo mokutil --import /path/to/meshstor-vendor.der

# 3. Reboot and complete enrollment via MokManager (same flow as Path 1).
sudo reboot

# 4. Install the prebuilt-modules .rpm.
sudo dnf install -y ./meshstor-ms-prebuilt-0.1.0-1.el10.x86_64.rpm
```

```bash
# 5. Verify.
sudo modprobe ms_mod raid1_ms raid10_ms
lsmod | grep -E '^ms_mod|^raid1_ms|^raid10_ms'
cat /proc/msstat
```

### Ubuntu 24.04 HWE / Ubuntu 26.04

```bash
# Steps 1-3 identical to RHEL path: mokutil --import, reboot, MokManager.

# 4. Install the prebuilt-modules .deb.
sudo apt install -y ./meshstor-ms-prebuilt_0.1.0-1_amd64.deb

# 5. Verify.
sudo modprobe ms_mod raid1_ms raid10_ms
lsmod | grep -E '^ms_mod|^raid1_ms|^raid10_ms'
cat /proc/msstat
```

The pre-built path needs a separate `.rpm`/`.deb` per (kernel-version
× distro) tuple, since the modules are kernel-vermagic-specific. The
build pipeline that produces them is documented in
[build.md](build.md#vendor-key-recommended-for-production).

## Path 3 — Secure Boot disabled (test/dev only)

For test or development hosts where Secure Boot is intentionally off,
no signing infrastructure is needed. The DKMS package builds the
modules and they load directly.

### Confirm Secure Boot is OFF

```bash
mokutil --sb-state
# Must report:  SecureBoot disabled
```

If it reports "SecureBoot enabled", either disable Secure Boot in
firmware (out of scope here) or use Path 1 / Path 2.

### Install (any supported distro)

RHEL family:

```bash
sudo dnf install -y ./meshstor-ms-dkms-0.1.0-1.el10.noarch.rpm
```

Ubuntu:

```bash
sudo apt install -y ./meshstor-ms-dkms_0.1.0-1_all.deb
```

Modules will be built and installed; signing happens but is unenforced
by the kernel. No reboot needed for first load.

```bash
sudo modprobe ms_mod raid1_ms raid10_ms
cat /proc/msstat
```

This path is appropriate only for build-system development and rapid
local iteration. Production hosts should use Path 1 or Path 2.

## What to do if it doesn't work

If `modprobe` fails, the array doesn't appear, or the build fails,
see the [troubleshooting section in admin.md](admin.md#troubleshooting).
The four most common failures are covered there:

- `modprobe ms_mod` fails or hangs (Secure Boot lockdown, missing
  kernel-modules-extra, kernel mismatch)
- DKMS build failed (where to find `make.log`, what to look for)
- Array does not appear after reboot (mdadm.conf, AUTOINSTALL)
- Kernel oops on first modprobe (RHEL 9 specific historical issue)

## Next steps

- [admin.md](admin.md) — operate arrays day-to-day
- [compat.md](compat.md) — confirm your distro/kernel is supported
- [performance.md](performance.md) — measured perf characteristics
