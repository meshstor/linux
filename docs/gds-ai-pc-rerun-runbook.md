# Runbook: re-run the full GDS/p2pdma validation on ai-pc with a new GPU

Written 2026-08-06 at the end of the session that built this rig, ran every
GPU-independent check, and root-caused why the GPU-native arm cannot run on the
current card. **Purpose: let a cold session, with a new GPU installed, re-run
the complete check list without re-deriving anything.**

Read this top to bottom before touching the machine. §1 (identity) and §2
(hazards) are not optional — one of them was learned by destroying data.

---

## 1. The machine, and how to identify things safely

AMD **Ryzen 7 7700X** (family 25 → `cpu_supports_p2pdma()` true), ASUS **ProArt
X670E-CREATOR WIFI**, BIOS 3902. This is the box previously called
`meshstor-pc`; **since the Ubuntu install it reports hostname `ai-pc`, which is
ALSO the name of a different, Intel box in older notes. Identify this box by CPU
(Ryzen 7700X), never by hostname.**

Triple boot, GRUB default = Ubuntu:

| OS | Where | Kernel | Role |
|---|---|---|---|
| **Ubuntu 26.04 LTS** (default) | `sda2` | `7.0.0-29-generic` | the validation platform |
| Rocky 10.1 | `sda3`, self-contained `/boot` | `6.12.0-124.8.1.el10_1` | el10 fence work (el10_2 kernels installable via dnf) |
| Windows | Kingston NVMe | — | **NEVER TOUCH** (see §2.1) |

Boot args already set on Ubuntu: `nvme_core.multipath=N iommu=pt`.

### Disks — resolve by identity, never by `/dev/nvmeXnY`

| Disk | Model | Size | Role |
|---|---|---|---|
| **WD_BLACK SN7100 1TB** | `WD_BLACK SN7100 1TB` | 931.5G | **test drive** — all test partitions |
| **Kingston KC3000** | `KINGSTON SKC3000S1024G` | 953.9G | **WINDOWS** — off limits |

At the time of writing WD = `nvme1n1`, Kingston = `nvme0n1`, **but these flipped
across a reboot during this session and that flip caused a data-loss incident.**
Confirm before every destructive step:

```bash
for d in /dev/nvme[0-9]n1; do
  echo "$d $(sudo nvme id-ctrl $d | grep -m1 '^mn ' | cut -c1-45) $(lsblk -dno SIZE $d)"
done
```

Test partitions on the WD drive (use the **partlabels**, not device names):

| Partlabel | Size | Purpose |
|---|---|---|
| `nvme1n1-meshstor-test-{1,2,3,4}` | 4 × 25G | gds-campaign substrate (needs 2 for raid1, 4 for raid10) |
| `p2p-local` | 25G | local leg of the mixed-leg reference rig |
| `p2p-back` | 25G | nvmet-rdma backing store for the remote leg |

Fabric: ConnectX-4 Lx dual port, **the two ports are cabled to each other**.
`enp3s0f0np0` = 10.99.0.1/30 (target), `enp3s0f1np1` = 10.99.0.2/30 (initiator);
both also carry 192.168.100.x. Management network is `eno2` (192.168.200.30) —
leave it alone.

---

## 2. Hazards — every one of these was paid for in this session

### 2.1 NVMe device names are NOT stable across reboots (data-loss incident)

A rig script with hardcoded `/dev/nvme0n1p2` / `p3` ran after a reboot in which
`nvme0n1` had become the **Kingston Windows drive**. It exported the 850 GB NTFS
Windows partition over nvmet-rdma, ran `wipefs -a` and `mdadm --zero-superblock`
on it, and assembled a raid1 across it and the Microsoft Reserved partition.

Damage was bounded (NTFS OEM ID, `$Boot` sectors 8–15, `$MFTMirr`) — **no file
data lost**, proven by comparing both legs' data areas (they differed, so no
resync bulk-copy ran) and by the primary `$MFT` at 3 GB reading `FILE0`.
**Repaired the same session** (§7). A red flag was ignored: `mdadm --create`
sized the array to **15 MB instead of 25 GB** because it sizes to the smallest
member — that means the wrong device was picked. **Stop and re-verify; never
"fix" it by zeroing superblocks.**

Rules now enforced in `bin/gds-rig-up`: resolve legs via
`/dev/disk/by-partlabel/`, and refuse outright if the parent disk carries
NTFS/EFI/Microsoft signatures.

### 2.2 In-kernel md auto-assembles ms arrays

The ms superblock is bit-for-bit identical to kernel md, so udev's incremental
assembly grabs ms members as `/dev/mdN` the moment ms releases them — breaking
any test that re-creates arrays, and a real product/ops hazard worth documenting
for customers.

**Fixed on this box** by `/etc/udev/rules.d/10-mdadm-no-udev-assemble.rules`
(sets `ENV{ANACONDA}="1"` on `linux_raid_member`, which
`64-md-raid-assembly.rules` honours as skip). **Verify it survived any reinstall:**

```bash
sudo mdadm --create /dev/ms0 --level=1 --raid-devices=2 --assume-clean --run \
    --bitmap=none /dev/disk/by-partlabel/nvme1n1-meshstor-test-{1,2}
sudo /home/mykola/mdadm/mdadm --stop /dev/ms0; sleep 3; cat /proc/mdstat   # must be "unused devices: <none>"
```

### 2.3 Ubuntu 26.04 ships Rust `uutils dd` — it FAILS O_DIRECT on ms arrays

`/usr/bin/dd` is uutils 0.8.0; its O_DIRECT buffer alignment fails on queues
reporting `dma_alignment=511` (md/ms default) while working on raw NVMe (3).
Measured on `/dev/ms0`: uutils → `dd: IO error: Invalid input` at every block
size; **`/usr/bin/gnudd` → 8 MiB at 4.2 GB/s**; `xfs_io`/`preadv` fine. The
kernel path is correct — the tool is not. Commit `07a06fa5` makes the campaign
and Layer-B lib prefer `/usr/bin/gnudd` via `$DD`. **Use `gnudd`, `xfs_io`, or
fio for any direct-I/O check; a bare `dd iflag=direct` produces a false failure.**

### 2.4 vng/QEMU launch flakiness

`vng` intermittently fails to launch (rc=255, empty vout.log) on back-to-back
boots — roughly half of attempts. `run_vm.sh` retries 5×, but the suite's 300 s
per-test timeout can kill it mid-retry, producing a **false FAIL**. Re-run a
failing test solo with `P2P_TEST_TIMEOUT=600` before believing it.

### 2.5 Tear down everything you start

Every VM/nvmet/array/loop device must be gone at session end (`no-orphaned-processes`
rule). `pgrep -f <pattern>` self-matches its own shell — verify with
`ps -eo pid,comm | awk '$2 ~ /^qemu/'` instead.

---

## 3. Why a new GPU is needed (do not re-derive)

Two independent NVIDIA gates, both verified from driver source and empirically:

1. **Brand gate** — GDS/cuFile is restricted to Data Center / pro cards.
   GeForce is excluded. (The A2000 clears this.)
2. **BAR1 ≥ VRAM** — undocumented by NVIDIA; comes from
   `kbusIsStaticBar1Supported_TU102`. `RMForceStaticBar1=1` (ENABLE) compares
   BAR1 against `memmgrGetClientFbAddrSpaceSize` and returns
   `NV_ERR_INVALID_REGISTRY_KEY` on failure, which is **fatal to
   `kbusInitBar1` → RmInitAdapter**. AUTO (the 580+/610 default) fails
   *gracefully* instead. UVM only creates PCI-P2PDMA pages when
   `static_bar1_size != 0 && !static_bar1_write_combined`
   (`uvm_devmem.c:627`) — hence `RmForceDisableIomapWC=1` is also required.

**The RTX A2000 12GB has max ReBAR 8 GB vs 12 GB VRAM → structurally impossible.**
`RMForceStaticBar1=1` wedges its GSP (`RmInitAdapter failed`), recoverable
**only by reboot** — FLR and PCI remove/rescan do not clear it. The
`OverrideFbSize=6144` workaround (which is correct in CPU-side RM by three
independent source reads) was tried and **GSP-RM rejects the carved framebuffer**
even in safe AUTO mode — empirically closed, do not retry.

### GPU purchase/verification rule

Max ReBAR size must **exceed** VRAM (power-of-two-VRAM cards where BAR == VRAM
likely fail: overheads + 512 MB alignment don't fit). Verified-good:
**RTX A5000 24 GB (32 GB BAR1, ~$1.2–1.6k used — recommended)**, A6000 48 GB
(64 GB), RTX PRO 6000 Blackwell (128 GB); RTX 5000/6000 Ada and RTX PRO 5000 via
Display Mode Selector `physical_display_disabled` (needs the **datacenter**
driver stream, kills display outputs). Avoid A4000 16 GB / RTX 2000 Ada 16 GB /
RTX PRO 4500 32 GB (BAR == VRAM). L4/L40S pass but are passive (bad in a desktop).

**Day one, before anything else:**

```bash
sudo lspci -vv -s $(lspci | awk '/VGA.*NVIDIA/{print $1}') | grep -A6 "Physical Resizable BAR"
#   BAR 1 "supported:" list MUST include a size > VRAM
nvidia-smi -q -d MEMORY | grep -A3 BAR1        # Total must be > VRAM
```

On 580+/610 a qualifying card auto-enables static BAR1 — **only**
`NVreg_RegistryDwords="RmForceDisableIomapWC=1"` should be needed. **Never set
`RMForceStaticBar1=1` on an unverified card**; if the GPU then fails to init,
delete `/etc/modprobe.d/nvidia-p2pdma.conf` and reboot.

---

## 4. Software state (already installed — verify, don't reinstall blindly)

```
nvidia-driver-610-open (dkms 610.43.02) + nvidia-modprobe
CUDA 13.3: gds-tools-13-3, libcufile-13-3   (/usr/local/cuda-13.3/gds/tools/{gdscheck,gdsio})
dkms, build-essential, virtme-ng 1.40, qemu 10.2.1, bpftrace 0.25.0,
fio 3.41, nvme-cli, xfsprogs (xfs_io), ntfs-3g, /usr/bin/gnudd (GNU coreutils 9.7)
meshstor-ms/0.1.0            → built from p2pdma tip 04e102cf, srcversion 86D80844CAB3DD7B32FF869
meshstor-nvme-rdma/0.2.0     → u2604 variant, override ACTIVE (beats in-tree nvme-rdma)
patched mdadm: /home/mykola/mdadm/mdadm  (also /usr/sbin/msadm)
```

**nvidia-fs is NOT built** (it fails against 7.0 headers: implicit
`blk_integrity_rq` + nvfs-mmap probe cascade). Only needed for the *legacy* GDS
path — cuFile p2pdma mode bypasses nvidia-fs entirely, so this does not block
native validation.

Repo: branch `gds-campaign`, HEAD `07a06fa5`, **15 commits ahead of origin,
unpushed** (all pushes are Mykola's). Feature branch worktree:
`.worktrees/p2pdma` at `04e102cf`. Design spec:
`docs/superpowers/specs/2026-08-05-gds-native-mixed-leg-uek8-design.md` (rev 5 —
note its UEK8 track is ON HOLD; the Ubuntu pivot in §"Rev 5" is what happened).

---

## 5. Already validated — DO NOT redo (baseline to compare against)

| Area | Result |
|---|---|
| QEMU p2pdma suite (22 tests, first ever run) | **18 pass / 0 real failures / 1 skip** — both apparent failures root-caused: one vng flake, one md-auto-assembly harness gap ("all cells matched v6 semantics") |
| dkms tooling suite | **12 pass / 0 fail / 1 skip** (git-filter-repo absent); u2604 nvme compiles clean vs 7.0.0-29; all 12 patches apply at fuzz=0 |
| Bare-metal advertise chain | both legs + `/dev/ms0` advertise `BLK_FEAT_PCI_P2PDMA`; member-AND gating proven |
| Data integrity | 64 MB pattern through `/dev/ms0`, mirrored to both legs, readback exact |
| Degraded mode | leg drop → `redirecting sector to other mirror` → `Operation continuing on 1 devices`; **v==2 latch fires** (`I/O error while the array advertises P2P (status=10)` — correctly NOT `no P2P path`); re-add → advertise re-evaluation clears it |
| gds-campaign (4 partitions) | **21 PASS / 15 FAIL / 9 SKIP** — 14 FAILs are GPU-gated (`p2p_bios=0 … cmd_rc=255`), 1 is an environment artifact (§6) |
| GPUDirect RDMA (dma-buf) | **2759 MiB/s** GPU↔NIC via `ib_write_bw --use_cuda --use_cuda_dmabuf`, **zero PCIe AER errors** — platform P2P routing proven healthy |
| CX-4 Lx dmabuf-MR | **WORKS** (`ibv_reg_dmabuf_mr` OK) — previously unanswered publicly; probe source: `tools/testing/selftests/md/p2pdma-vm/gds/dmabuf_probe.c` |

Hardware health: all links at spec (GPU Gen4 x8 under load — x8 is the board's
hard bifurcation with slot 2 populated, not a fault), zero MCEs, zero AER.

---

## 6. Known non-defects (expect these; do not chase)

- **`p4 layerb_test_nonp2p_merge_control` FAILs** — "REQ_NOMERGE may be
  over-preserved". Proven environment artifact: a **raw partition with no ms
  involved shows zero write merges too**, at disk and partition level, with both
  `none` and `mq-deadline` schedulers. This NVMe does not merge under that
  workload. The test should SKIP when a raw control shows no merges (not fixed).
- **`p7c`/`p7g`/`p7h` SKIP** — cuFile compat/member-transport policy, banked as
  product escalations.
- **`p7f` SKIP** — no cross-root-complex NVMe pair (all test partitions on one disk).
- **`p5` SKIP** — no kit tarball; needs `bin/gds-make-kit`.

---

## 7. Windows disk state (repaired — verify only)

Repaired at end of session: boot sector restored from NTFS's intact backup copy,
md superblock removed, md bitmap remnants zeroed (8 KB–176 KB, exact extent
mapped), `ntfsfix` run (reset `$UpCase`, emptied `$LogFile`, **set the dirty
flag so Windows runs chkdsk on next boot**), MSR partition's RAID signature
cleaned. Verified by read-only mount: `Windows/`, `Users/` with real profiles,
`System32/ntoskrnl.exe` at 13,039,048 bytes.

**Outstanding:** Windows has not been booted since. Expect chkdsk to run and
rebuild `$MFTMirr` from the intact primary `$MFT`. If Windows fails to boot, the
`$Boot` bootstrap sectors 8–15 (zeroed) can be rebuilt with `bootrec /fixboot`
from Windows Recovery — the EFI partition holding the actual bootloader was
never touched. Byte backups live in `build/gds-rerun-assets/` (`win-p3-first1M.bak`,
`win-p3-backupboot.bak`, `win-p2-msr-first1M.bak`). They are deliberately NOT
committed -- recovery artifacts, not repo material -- and `build/` is
gitignored, so copy them somewhere durable if you still want them.

---

## 8. THE RE-RUN LIST (with a qualifying GPU installed)

Run in this order. Everything before §8.4 is a regression check of what already
passed; §8.4–8.6 is the new coverage the GPU unlocks.

### 8.0 Pre-flight (5 min)

```bash
cd /home/mykola/linux-meshstor
uname -r; cat /proc/cmdline | tr ' ' '\n' | grep -E 'multipath|iommu'   # 7.0.0-29, N + pt
grep CONFIG_PCI_P2PDMA /boot/config-$(uname -r)                          # =y
for d in /dev/nvme[0-9]n1; do echo "$d $(sudo nvme id-ctrl $d | grep -m1 '^mn ' | cut -c1-45)"; done   # §1
ls /etc/udev/rules.d/10-mdadm-no-udev-assemble.rules                     # §2.2
dkms status; cat /sys/module/ms_mod/srcversion 2>/dev/null
# GPU gates — the whole point of the new card:
sudo lspci -vv -s $(lspci | awk '/VGA.*NVIDIA/{print $1}') | grep -A6 "Physical Resizable BAR"
nvidia-smi -q -d MEMORY | grep -A3 BAR1
```

If the driver needs the WC key: `/etc/modprobe.d/nvidia-p2pdma.conf` with
`options nvidia NVreg_RegistryDwords="RmForceDisableIomapWC=1"`, then reboot
(driver reload alone is unreliable — nvidia_drm/modeset hold references; unbind
`vtcon1` first if you must avoid a reboot).

Then confirm cuFile sees the GPU as p2pdma-capable — **this is the gate that
failed on the A2000**:

```bash
SP=<your scratchpad>; cp /etc/cufile.json $SP/cufile-native.json
# Edit these keys (line numbers drift between CUDA releases -- grep, don't seek):
#   properties.use_pci_p2pdma      = true
#   properties.allow_compat_mode   = false     (so any fallback is a loud failure)
#   profile.cufile_stats           = 3         (gds_stats needs this)
#   block.nvme.use_pci_p2pdma      = true
#   block.nvmeof.use_pci_p2pdma    = true      (fabric leg)
#   block.raid.use_pci_p2pdma      = true      (THE array itself -- default false)
#   fs.generic.posix_unaligned_writes = false ; posix_gds_min_kb = 0
#   logging.dir = $SP ; logging.level = DEBUG  (to read the 801 diagnosis)
CUFILE_ENV_PATH_JSON=$SP/cufile-native.json /usr/local/cuda-13.3/gds/tools/gdscheck -p
grep -iE 'p2pdma|801' $SP/cufile_*.log      # must NOT say "gpu attribute pci_p2pdma not supported"
```

### 8.1 Rebuild ms + nvme-rdma for the running kernel (if kernel changed)

```bash
env KERNEL_TREE=$PWD/.worktrees/p2pdma KDIR=/lib/modules/$(uname -r)/build bin/build-tarball 0.1.0
sudo rm -rf /usr/src/meshstor-ms-0.1.0 && sudo tar xzf build/meshstor-ms-0.1.0.dkms.tar.gz -C /usr/src/
sudo dkms install meshstor-ms/0.1.0 && sudo modprobe ms_mod raid1_ms raid10_ms && cat /proc/msstat
bin/build-nvme-tarball 0.2.0
sudo rm -rf /usr/src/meshstor-nvme-rdma-0.2.0 && sudo tar xzf build/meshstor-nvme-rdma-0.2.0.dkms.tar.gz -C /usr/src/
sudo dkms install meshstor-nvme-rdma/0.2.0 && sudo modprobe nvme-rdma
# assert identity:
modinfo -F srcversion /lib/modules/$(uname -r)/updates/dkms/ms_mod.ko.zst; cat /sys/module/ms_mod/srcversion
```

### 8.2 QEMU p2pdma suite — real p2pdma pages, GPU-independent (~30 min)

```bash
SP=<scratchpad>; mkdir -p $SP/msmods
for m in ms_mod raid1_ms raid10_ms; do sudo zstd -dqf /var/lib/dkms/meshstor-ms/0.1.0/$(uname -r)/x86_64/module/$m.ko.zst -o $SP/msmods/$m.ko; done
make -C .worktrees/p2pdma/tools/testing/selftests/md/p2pdma/modules   # injector for THIS kernel
sudo env MD_SUBSYS=ms MS_MOD_DIR=$SP/msmods MDADM=/home/mykola/mdadm/mdadm TMPDIR=$SP \
     bash .worktrees/p2pdma/tools/testing/selftests/md/p2pdma/run_all.sh
```
Baseline: 18 pass / 1 skip. Re-run any FAIL solo with `P2P_TEST_TIMEOUT=600`
before believing it (§2.4). Note the suite's log is polluted with VM serial
padding — `tr -d '\000'` it.

### 8.3 dkms tooling suite (~5 min)

```bash
env KERNEL_TREE=$PWD/.worktrees/p2pdma bash tools/testing/selftests/dkms/run_all.sh
```
Baseline: 12 pass / 0 fail / 1 skip.

### 8.4 Bare-metal mixed-leg rig + GPU-native I/O  ← THE NEW COVERAGE

```bash
sudo bin/gds-rig-up                     # partlabel-resolved, refuses NTFS/EFI parents (§2.1)
cat /sys/block/ms0/ms/p2pdma_status     # array advertise=yes; both members advertise
sudo mkfs.xfs -f /dev/ms0 && sudo mkdir -p /mnt/p2p && sudo mount /dev/ms0 /mnt/p2p
CUFILE_ENV_PATH_JSON=$SP/cufile-native.json /usr/local/cuda-13.3/gds/tools/gdsio \
    -f /mnt/p2p/t1 -d 0 -w 4 -s 1G -i 1M -x 0 -I 1     # WRITE phase: only writes light up both legs
```
Assert **all** of:
1. gdsio succeeds with `allow_compat_mode=false` (success ⇒ native);
2. `gds_stats` shows GDS bytes, **zero** posix/bounce ops (needs `cufile_stats=3`);
3. witness sees P2P maps from **both** the local nvme *and* the mlx5 device:
   `gds-p2p-witness --expect-ms nonzero --require-dev <nvme-BDF> --require-dev <mlx5-BDF> -- <gdsio ...>`
   (witness rewritten 2026-08-06 — see §9; run its positive control first);
4. per-leg readback: content matches on the local partition *and* via the nvmet
   backing partition.

### 8.5 Degraded mode (GPU-independent, but re-run under native I/O)

```bash
sudo nvme disconnect -n mesh-loop      # or: ip link set <target port> down
cat /proc/msstat; cat /sys/block/ms0/ms/p2pdma_status; sudo dmesg | tail -6
```
Expect: `[U_]`, continues on local leg, latch `observed=other` (v==2 wording),
data intact. Then reconnect + `mdadm --add` → advertise re-evaluation clears it.
The genuine `no P2P path` (v==1) breadcrumb needs a *mapping* failure, which the
QEMU suite (§8.2) covers — do not expect it from a transport drop.

### 8.6 gds-campaign, full (~40 min)

```bash
sudo env MDADM=/home/mykola/mdadm/mdadm PATH=$PATH:/usr/local/cuda-13.3/gds/tools \
     bin/gds-campaign --rehearsal --results $SP/gds-new
awk -F'\t' '{print $1,$2,$3,"|",$4}' $SP/gds-new/verdict.tsv
```
Compare against §5's 21/15/9. **With a working GPU the 14 GPU-gated FAILs
(p1 native, p1 raw_baseline, p2 native, p2 raid1_local, p3 native ×2,
raid1_fabric, raid10_fabric, p7a ×2, p7b ×2, p7d ×2) should flip to PASS** —
that is the headline result of the re-run. `merge_control` will still FAIL (§6).

### 8.7 Teardown

```bash
sudo umount /mnt/p2p; sudo /home/mykola/mdadm/mdadm --stop /dev/ms0
sudo nvme disconnect -n mesh-loop
sudo sh -c 'rm -f /sys/kernel/config/nvmet/ports/1/subsystems/*; rmdir /sys/kernel/config/nvmet/ports/1 /sys/kernel/config/nvmet/subsystems/*/namespaces/1 /sys/kernel/config/nvmet/subsystems/*' 2>/dev/null
ps -eo pid,comm | awk '$2 ~ /^(qemu|vng|fio|gdsio)/'      # must be empty
```

---

## 9. Known-broken tooling to fix before trusting it

- **`bin/gds-p2p-witness` was REWRITTEN 2026-08-06 — it is now usable.** It
  auto-detects the map anchor (`__pci_p2pdma_update_state` on 7.x/el10,
  `pci_p2pdma_map_segment` on vanilla 6.12; device is arg1 in both) and the
  ZONE_DEVICE accessor (`folio->pgmap` vs `page->pgmap`), each compile-tested
  with `bpftrace --dry-run` so a layout change SKIPs instead of miscounting.
  The `pci_p2pdma_*` glob fallback is gone (it counted one-time
  `pci_p2pdma_add_resource` registration and polluted zero-windows) — no anchor
  now means exit 4. **New `--require-dev SUBSTR` (repeatable) is the assertion
  §8.4 needs**: it fails unless that device actually mapped P2P, so "both legs
  mapped" is expressible — the old summed counter could not say this and would
  pass when only the local leg mapped. Also new: `--expect-dma-zero zero`
  (catches the el10 `dma_address=0`-with-success class; only meaningful on the
  `pci_p2pdma_map_segment` anchor, which exposes an sg) and `--selftest`
  (negative control). Report line gained `map_devs=[...] dma_zero=N anchor=...`;
  the legacy `p2p_bios=/host_bios=/map_hits=/cmd_rc=` prefix, all existing
  flags, and exit codes 0/1/2/4 are unchanged, so existing callers are
  unaffected. Verified on 7.0.0-29: anchor + folio cast auto-selected,
  negative control clean, 2091 host bios correctly classified with zero false
  P2P, `--require-dev` correctly FAILS for a leg that never mapped, legacy
  all-any rc passthrough intact.
  **Still to do on the new GPU: the POSITIVE control** — run a native gdsio
  under the witness and require `@p2p_bios>0` plus `--require-dev` for both the
  local NVMe BDF and the mlx5 BDF. Until that fires once, treat a green witness
  as unproven.
- **`p2p_make_array`/`p2p_cleanup`** in the p2pdma suite `lib.sh` should evict
  `/dev/md*` before re-creating (the udev rule handles it on this box, but the
  suite is not portable without it).
- **`merge_control`** should SKIP when a raw control shows no merges (§6).

---

## 10. Open questions worth resolving during the re-run

1. Does the new GPU report `pci_p2pdma` supported **without** `RMForceStaticBar1`
   (expected on 580+/610 AUTO if BAR1 > VRAM)? Record the exact
   `NVreg_RegistryDwords` needed — it goes in the product config doc.
2. Does cuFile actually take the p2pdma path **through an md/ms array**? NVIDIA
   docs say RAID is "not enabled … without a specialized patch" — if it works,
   the reference config must state plainly that this is a **meshstor-validated**
   configuration, not an NVIDIA-supported one.
3. Real fabric: the rdma leg is currently a **same-host loopback** over cabled
   ports. Wire-crossing was never forced (policy routing untested;
   `nvmet` cannot leave `init_net` — the exclusive-netns plan in the spec is
   structurally impossible). Target-side P2P is NOT exercised at all (nvmet
   serves from host memory) — say so in the config doc.
4. KvikIO reference workload was never installed (`kvikio-cu13` wheels exist).
   Gate it on `KVIKIO_COMPAT_MODE=OFF` + strict cufile + `gds_stats` + witness —
   **never** on KvikIO's own compat inference (it falls back silently).

---

## 11. Ground rules (carried forward)

- **All pushes/sends are Mykola's, manually.** Branch `gds-campaign` is 15
  commits ahead of origin; stage commands, never run them.
- This runbook is tracked (`docs/gds-ai-pc-rerun-runbook.md`); the
  `docs/superpowers/` archive is gitignored and now only holds a pointer to it.
- Tear down every VM/array/target you start (§2.5).
- Assessment ≠ authorization: discovered blockers are findings to report, not
  work orders.
