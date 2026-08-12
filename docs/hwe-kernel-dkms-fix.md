# Runbook: HWE kernel install fails because DKMS modules can't build

**Symptom:** `apt install linux-generic-hwe-24.04` (or any new kernel) ends with
`dpkg: error processing package linux-headers-<KVER> / linux-image-<KVER>` because
`/etc/kernel/{header_,}postinst.d/dkms` exits 1 — vendor DKMS modules
(mlnx-ofed-kernel, lustre, vastnfs, knem, kernel-mft, nvidia) fail to build for the
new kernel. dpkg is left with 4 unconfigured packages and every later apt run fails.

**Root cause pattern (verified 2026-07-02 on gpu-cluster-manassas, HWE 6.17):**

1. The Mellanox/DDN/VAST stack (OFED 24.10, lustre 2.14, vastnfs, knem, mft) genuinely
   does not support the new kernel — their configure/kbuild breaks (OFED conftest fails,
   `-I$(PWD)` Makefiles broke with kbuild ≥ 6.13).
2. **nvidia is usually collateral damage, not broken**: its Kbuild auto-links against
   `/usr/src/ofa_kernel/<arch>/<KVER>/Module.symvers` whenever that directory exists.
   OFED's failed `pre_build.sh` leaves the directory **half-populated** (no
   `Module.symvers`), so nvidia compiles 100% and then dies at MODPOST.

The fix: delete the stale OFED artifact so nvidia builds, gate the genuinely
incompatible modules so DKMS *skips* them (exit 77) instead of failing the kernel
postinst, then let dpkg finish.

---

## 0. Set the target kernel version

```bash
export KVER=6.17.0-35-generic     # the kernel that failed to configure
```

## 1. Diagnose (30 seconds)

```bash
# Which modules failed vs skipped vs built:
dkms status | sort

# Real error of each failed module (nvidia failing on ofa_kernel Module.symvers = collateral):
for d in /var/lib/dkms/*/*/build/make.log; do echo "===== $d"; tail -n 15 "$d"; done 2>/dev/null | less

# The tell-tale stale OFED artifact (dir exists but no Module.symvers => nvidia will fail MODPOST):
ls /usr/src/ofa_kernel/x86_64/$KVER/Module.symvers
```

## 2. Un-break nvidia: remove the stale ofa_kernel tree and rebuild

```bash
sudo rm -rf /usr/src/ofa_kernel/x86_64/$KVER
NVVER=$(ls /var/lib/dkms/nvidia/)   # e.g. 580.126.16
sudo dkms build nvidia/$NVVER -k $KVER    # should end: "Building module(s)... done" + signing
```

## 3. Gate the modules that genuinely can't build on the new kernel

`BUILD_EXCLUSIVE_KERNEL` makes dkms **skip** (not fail) autoinstall on non-matching
kernels — the designed mechanism, supported by dkms ≥ 3.x. Regex below pins them to
the 6.8 GA kernel; adjust if the known-good kernel differs.

```bash
for src in \
    /usr/src/kernel-mft-dkms-* \
    /usr/src/knem-* \
    /usr/src/lustre-client-modules-* \
    /usr/src/mlnx-ofed-kernel-* \
    /usr/src/vastnfs-*; do
  grep -q BUILD_EXCLUSIVE_KERNEL "$src/dkms.conf" && { echo "already gated: $src"; continue; }
  printf '\n# ops %s: this version does not build on kernels > 6.8; skip autoinstall\n# there instead of failing kernel postinst. Remove when a capable version ships.\nBUILD_EXCLUSIVE_KERNEL="^6\\.8\\."\n' \
    "$(date +%F)" | sudo tee -a "$src/dkms.conf" >/dev/null
  echo "gated: $src"
done
```

## 4. Clear stale apport reports and finish the install

The `Cannot create report: [Errno 17] File exists` noise comes from leftover crash
files; remove the dkms ones so future failures report cleanly.

```bash
sudo rm -f /var/crash/*-dkms.0.crash /var/crash/nvidia-kernel-source-*.crash
sudo dpkg --configure -a
```

Expected in the output:

```
Autoinstall on <KVER> succeeded for module(s) nvidia xpmem.
Autoinstall on <KVER> was skipped for module(s) kernel-mft-dkms knem lustre-client-modules mlnx-ofed-kernel vastnfs.
```

## 5. Verify

```bash
sudo dpkg --audit && echo "dpkg clean"                      # must print nothing above "dpkg clean"
dkms status | grep $KVER                                    # nvidia + xpmem: installed
ls /lib/modules/$KVER/updates/dkms/                          # nvidia*.ko.zst + xpmem.ko.zst
ls /boot/initrd.img-$KVER /boot/vmlinuz-$KVER               # initramfs regenerated
```

## Before rebooting into the new kernel — know what you lose

- The new kernel runs with **in-box mlx5** only: no OFED extras, no lustre client,
  no vastnfs, no knem, no mft. Check nothing mounted depends on them:
  `findmnt -t lustre,nfs,nfs4` and `grep -E 'lustre|vast' /etc/fstab`.
- `openibd.service` will log a failure on the new kernel — harmless, doesn't gate
  `networking.service`.
- SSH safety: confirm the management NIC driver exists in-box for the new kernel,
  e.g. `find /lib/modules/$KVER -name 'i40e.ko*' -o -name 'bonding.ko*'`.
- Optional belt-and-suspenders: keep old kernel as GRUB default and one-shot boot
  the new one, so a BMC power-cycle auto-reverts:

  ```bash
  # set GRUB_DEFAULT=saved + grub-set-default to the old kernel, then:
  sudo grub-reboot "Advanced options for Ubuntu>Ubuntu, with Linux $KVER"
  sudo reboot
  ```

## Undo / later

- **Gates are plain appended lines** in `/usr/src/<pkg>-<ver>/dkms.conf` — delete the
  `BUILD_EXCLUSIVE_KERNEL` line and rerun
  `sudo dkms autoinstall -k $KVER` when a kernel-capable package version ships.
- **Package upgrades of the five gated packages overwrite the gates** (they replace
  `/usr/src/<pkg>-<newver>/`) — expect to re-apply step 3 after an OFED/lustre/vastnfs
  upgrade that still doesn't support the kernel.
