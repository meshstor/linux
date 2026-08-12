# Runbook: re-run the full GDS/p2pdma validation on ai-pc with a new GPU

Written 2026-08-06 at the end of the session that built this rig, ran every
GPU-independent check, and root-caused why the GPU-native arm cannot run on the
current card. **Purpose: let a cold session, with a new GPU installed, re-run
the complete check list without re-deriving anything.**

**Revised 2026-08-06 (later same day)** after executing §8.0–8.3 a second time,
still on the A2000. Both suites reproduced their baselines exactly
(§5). That pass cost far more wall clock than this document implied, almost
entirely in two avoidable traps — Rocky's GRUB stripping Ubuntu's boot args
(§2.6) and the suite's output vanishing when redirected (§2.7) — plus vng
flakiness far worse than §2.4 originally described. Those three sections and
the §8 time budget are the substantive additions; read them first.

Read this top to bottom before touching the machine. §1 (identity) and §2
(hazards) are not optional — one of them was learned by destroying data.

---

## 1. The machine, and how to identify things safely

AMD **Ryzen 7 7700X** (family 25 → `cpu_supports_p2pdma()` true), ASUS **ProArt
X670E-CREATOR WIFI**, BIOS 3902. This is the box previously called
`meshstor-pc`; **since the Ubuntu install it reports hostname `ai-pc`, which is
ALSO the name of a different, Intel box in older notes. Identify this box by CPU
(Ryzen 7700X), never by hostname.**

Triple boot. **The firmware boots Rocky's GRUB (`BootCurrent: 0000`), and
Rocky's GRUB is the multiboot menu for all three OSes.** Ubuntu's own GRUB is
reached only through the chainload entry. Rocky's menu was rebuilt 2026-08-06
(§2.6) — before that it dropped Ubuntu's boot args, which silently invalidates
§8.4–8.6.

| OS | Where | Kernel | Role |
|---|---|---|---|
| **Ubuntu 26.04 LTS** (Rocky-GRUB default) | `sda2` | `7.0.0-29-generic` | the validation platform |
| Rocky 10.1 | `sda3`, self-contained `/boot` | `6.12.0-124.8.1.el10_1` | el10 fence work (el10_2 kernels installable via dnf) |
| Windows | Kingston NVMe | — | **NEVER TOUCH** (see §2.1) |

Boot args required on Ubuntu: `nvme_core.multipath=N iommu=pt`. **Verify them
in `/proc/cmdline`, never by reading a config file** — they are present in
Ubuntu's `/etc/default/grub` *and* in Rocky's menu entry, and were still absent
from the running kernel (§2.6).

### Disks — resolve by identity, never by `/dev/nvmeXnY`

| Disk | Model | Size | Role |
|---|---|---|---|
| **WD_BLACK SN7100 1TB** | `WD_BLACK SN7100 1TB` | 931.5G | **test drive** — all test partitions |
| **Kingston KC3000** | `KINGSTON SKC3000S1024G` | 953.9G | **WINDOWS** — off limits |

The mapping has now flipped **twice**: it was WD=`nvme1n1`/Kingston=`nvme0n1`
when this runbook was written, and on the 2026-08-06 re-run it came up the
other way round — WD=`nvme0n1`, Kingston(Windows)=`nvme1n1`. The first flip
caused a data-loss incident. Treat the names as random on every boot; note the
partlabels still read `nvme1n1-meshstor-test-*` from when they were created, so
**the label text does not track the device either** — only the symlink does.
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
both also carry 192.168.100.x. The **10.99 addresses are not persistent** —
`bin/gds-rig-up` adds them on each run, so they are absent until §8.4; only the
192.168.100.x ones survive a reboot. Both mlx5 ports come up ACTIVE/LinkUp at
25 Gb/s.

Management network is **`eno1` = 192.168.200.31** (corrected 2026-08-06; this
doc previously said `eno2`/192.168.200.30, and there is no `eno2` on the box) —
leave it alone. **A session working on this machine is normally SSH'd into it,
so `sudo reboot` kills that session**; plan §2.6 reboots accordingly.

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

### 2.4 vng/QEMU launch flakiness — the dominant source of false FAILs

`vng` intermittently fails to launch (rc=255, empty vout.log). `run_vm.sh`
retries 5×, but the suite's 300 s per-test timeout kills it mid-retry,
producing a **false FAIL**.

**Measured on the 2026-08-06 re-run, and much worse than "roughly half":**
**33 retry events in a single suite pass, and 5 of 19 tests failed — every one
of them a vng artifact, zero real defects.** Two distinct shapes, don't confuse
them:

- `rc=255` — all 5 boots failed, guest verdict never arrived, **the test never
  ran**. No information either way.
- `rc=124` — timeout. Either retries ate the budget, or the VM booted and then
  never powered off.

Neither is evidence of a defect. The host is not the problem — 56 GB free,
load ~1, no KVM errors in dmesg; it is a vng/virtme-ng launch bug.

**Therefore: run the suite at `P2P_TEST_TIMEOUT=600` from the start** (§8.2),
and re-run every failure solo before believing it. On the re-run all five
failures passed, including one that needed two solo attempts. A test that
still fails solo with a *test-authored* message (`FAIL: <assertion>`) is worth
investigating; a bare `rc=124`/`rc=255` is not.

### 2.5 Tear down everything you start

Every VM/nvmet/array/loop device must be gone at session end (`no-orphaned-processes`
rule). `pgrep -f <pattern>` self-matches its own shell — verify with
`ps -eo pid,comm | awk '$2 ~ /^qemu/'` instead. (Confirmed the hard way on
2026-08-06: `pgrep -f 'bash .*run_all.sh'` matched the very shell running the
`pgrep`, and reading `/proc/<pid>/fd/1` of that self-match printed the
command's own output back — a convincing-looking but entirely circular result.)

To stop a running suite, **SIGTERM, never SIGKILL** — SIGTERM lets
vng/virtme-run reap qemu; SIGKILL orphans it (`run_all.sh`'s header explains
why). Verify with the `ps -eo pid,comm` form above; three clean stops during
the 2026-08-06 re-run left zero orphans.

### 2.6 Rocky's GRUB silently strips Ubuntu's boot args (invalidates §8.4–8.6)

**Fixed 2026-08-06, but verify it survived — this one produces wrong results
rather than an error.** The firmware boots Rocky (`BootCurrent: 0000`), and
Rocky's `30_os-prober` had generated the Ubuntu entry from a *stale snapshot*
of Ubuntu's `grub.cfg`, carrying only `ro crashkernel=…` — **no
`nvme_core.multipath=N`, no `iommu=pt`** — while Ubuntu's own `/etc/default/grub`
and `grub.cfg` both looked correct. The box therefore booted with
`multipath=Y` (the nvme-rdma leg then cannot advertise `BLK_FEAT_PCI_P2PDMA`,
so member-AND gating turns the array's advertise off) and `iommu=DMA-FQ`
instead of passthrough (changes the THRU_HOST_BRIDGE mapping path — the same
axis as the el10 `dma_address=0` bug). The os-prober menu had also gone stale
in a second way: it still offered a `7.0.0-14` kernel that no longer exists.

The fix, in Rocky:

- `GRUB_DISABLE_OS_PROBER=true` in `/etc/default/grub` (stale entries gone),
  plus `GRUB_TIMEOUT_STYLE=menu` and `grub2-editenv - unset menu_auto_hide`
  (the menu was being suppressed entirely).
- Three explicit entries in `/etc/grub.d/40_custom`:
  `ubuntu-meshstor` (kernel-pinned, args spelled out), `ubuntu-chainload`
  (`configfile` into Ubuntu's own grub.cfg — never goes stale), and `windows`
  (`chainloader` to `/EFI/Microsoft/Boot/bootmgfw.efi` on the **Kingston** ESP,
  FAT UUID `D8F1-4B9B`; os-prober never found Windows because its bootloader
  is on a second ESP, not the shared `sda1` one). Secure Boot is off, so a
  direct chainload is valid.
- `grub2-set-default ubuntu-meshstor` (so a headless `sudo reboot` lands in
  Ubuntu with the right args) and `set fallback=ubuntu-chainload` (so a future
  Ubuntu kernel update cannot strand an SSH-only box on a pinned entry that no
  longer resolves).

Gotchas paid for: `sed -i` and `grub2-mkconfig` both replace the inode and
**drop the SELinux label** (Rocky is enforcing) — re-set `bootloader_etc_t` on
`/etc/default/grub` and `boot_t` on `grub.cfg`. And never leave a backup copy
of a `grub.d` script *inside* `/etc/grub.d/`: it stays executable and
`grub2-mkconfig` runs it, emitting a duplicate menu section. Originals are in
Rocky's `/root/grub-backup-20260806/`.

### 2.7 The suite's output must go through a pipe, or you lose all of it

Redirecting the p2pdma suite to a file — the obvious
`run_all.sh > suite.log 2>&1` — yields an **empty file**, even as the run
proceeds normally. The test's stdout is inherited down through `run_vm.sh` →
`vng` → `virtme-run`, which treats a regular-file stdout as the VM console and
truncates/seeks it. The tell is that the writer's fd offset advances
(`/proc/<pid>/fdinfo/1` shows `pos: 415`) while the file itself stays 0 bytes,
and the path's inode number changes underneath it.

Cost when not known: ~25 minutes and three restarted suite runs on 2026-08-06,
including two wrong theories (a `TMPDIR` collision, then a sandbox overlay).
**Give the VM a pipe, never a regular file** — see the §8.2 recipe.

### 2.8 `--add` of a reconnected fabric leg: observed once, NOT reproducible

**Do not treat this as a known bug.** On 2026-08-06 a first attempt to recover
the rdma leg (`nvme disconnect` → `nvme connect` → `mdadm --add`) produced
`mdadm: Failed to write metadata to /dev/nvme3n2`, and a later `--add` **hung**
(killed at 90 s and at 300 s) with no kernel message, no D-state task, and the
controller `live`. It was written up here as an open defect. **A deliberate
attempt to reproduce it, the same day on the same box, failed four times.**

Reproduction matrix — every cell SUCCEEDED, `mdadm` returning 0 with
`ADD_NEW_DISK` completing in 5–23 ms:

| # | Superblock on returning device | Array mounted | Dead member still in array | Result |
|---|---|---|---|---|
| 1 | intact | no | removed first | `re-added`, ok |
| 2 | zeroed (forces a *fresh* add) | no | removed first | `added`, ok |
| 3 | intact | **yes** (XFS, active) | removed first | `re-added`, ok |
| 4 | intact | **yes** | **still present (F)** | `added`, ok |

`strace` on the successful runs shows the superblock write completing normally
(`write(…, 4096) = 4096`, `fsync = 0`, then `ADD_NEW_DISK = 0`), which is
exactly the step that had reported failure.

What the original episode therefore proves is only that a **transient** state
can make `--add` fail and then block; its cause was not found. Two things
plausibly contributed and are worth ruling out first if it recurs: the failing
attempts ran ~3 s after `nvme connect`, while udev may still have been holding
the fresh device, and the diagnostic `gnudd` zero-writes issued at offsets 0 and
4096 during triage destroyed the superblock mid-sequence, so later attempts were
not operating on the state the earlier ones saw.

**If you hit it: capture `strace -f -T` of the hanging `mdadm`, plus
`cat /proc/<pid>/stack`, `/proc/mdstat`, and `fuser -v <device>`, before killing
anything** — that evidence is what this episode lacks. `bin/gds-rig-up` rebuilds
a healthy `[UU]` array, so it never blocks progress.

Note the returning namespace does get a **new name** (`nvme2n1` → `nvme3n2` or
`nvme4n1`, nsid still 1); that part is real and expected, and it means recovery
is `--remove detached` followed by `--add`, not `--re-add` on the old path.

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

Repo: branch `gds-campaign`, HEAD `a3be4e12` (2026-08-06: origin has caught up,
1 commit ahead — re-check with `git rev-list --count origin/gds-campaign..gds-campaign`
rather than trusting this line; all pushes are Mykola's). Feature branch worktree:
`.worktrees/p2pdma` at `04e102cf`. Design spec:
`docs/superpowers/specs/2026-08-05-gds-native-mixed-leg-uek8-design.md` (rev 5 —
note its UEK8 track is ON HOLD; the Ubuntu pivot in §"Rev 5" is what happened).

---

## 5. Already validated — DO NOT redo (baseline to compare against)

| Area | Result |
|---|---|
| QEMU p2pdma suite (19 test files, first ever run) | **18 pass / 0 real failures / 1 skip** — both apparent failures root-caused: one vng flake, one md-auto-assembly harness gap ("all cells matched v6 semantics") |
| QEMU p2pdma suite — **re-confirmed 2026-08-06** | **18 pass / 0 fail / 1 skip**, identical. Raw run was 13/5/1; *all five* failures passed on solo re-run (§2.4). The skip is always `route_fence_el10` (el10-only). Notable evidence: `badblocks_exhaustion` faulted at write #513 of 520, limit 512 — exactly `MAX_BADBLOCKS + 1` |
| dkms tooling suite | **12 pass / 0 fail / 1 skip** (git-filter-repo absent); u2604 nvme compiles clean vs 7.0.0-29; all 12 patches apply at fuzz=0 — **re-confirmed identical 2026-08-06** |
| Bare-metal advertise chain | both legs + `/dev/ms0` advertise `BLK_FEAT_PCI_P2PDMA`; member-AND gating proven — **re-confirmed 2026-08-06** (`array advertise=yes policy=auto`, both members `advertise=yes`). Note this is exactly what `multipath=Y` makes unreachable (§2.6), so it doubles as the boot-arg check |
| Data integrity | 64 MB pattern through `/dev/ms0`, mirrored to both legs, readback exact — **re-confirmed 2026-08-06**: identical md5 on the array, the local partition, and the nvmet backing store. Read the legs at `Data Offset` from `mdadm --examine` (34816 sectors here) with `gnudd iflag=direct,skip_bytes` |
| Degraded mode | leg drop → `redirecting sector to other mirror` → `Operation continuing on 1 devices`; **v==2 latch fires** (`I/O error while the array advertises P2P (status=10)` — correctly NOT `no P2P path`); re-add → advertise re-evaluation clears it |
| Degraded mode — 2026-08-06 | `[2/1] [U_]`, `Operation continuing on 1 devices`, degraded write ok, data intact. **Re-add re-confirmed** across 4 fail/recover cycles: `--remove detached` + `--add` → resync → `[UU]`, **advertise re-evaluation correct** (new member and array both `advertise=yes`), files intact throughout. Only gap: **the v==2 latch did NOT fire, correctly** — the writes were ordinary O_DIRECT (never P2P-tagged) and the leg dropped while idle, so the failure surfaced as `ms: super_written gets error=-5`. The latch needs a P2P-tagged bio to error while the array advertises, i.e. GPU-native I/O in flight, so **it is unvalidatable on the A2000** |
| gds-campaign (4 partitions) | **21 PASS / 15 FAIL / 9 SKIP** — 14 FAILs are GPU-gated (`p2p_bios=0 … cmd_rc=255`), 1 is an environment artifact (§6) |
| gds-campaign — **re-run 2026-08-06** | **23 PASS / 15 FAIL / 9 SKIP.** FAIL and SKIP sets **identical to baseline, member for member** (the 14 GPU-gated + `p4 merge_control`). PASS gained 2; the prior run's `verdict.tsv` no longer exists so the delta is **unattributed** — the plausible candidates are the fabric-dependent `rdma_gate`/`advertise_consistency` checks, which could not have behaved correctly under the `multipath=Y` boot (§2.6), but this is inference, not evidence. **Keep a copy of `verdict.tsv` this time** so the next run can diff |
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

**Budget, measured on the 2026-08-06 re-run** (the original per-step estimates
were optimistic — §8.2 alone is the bulk of it):

| Step | Estimate | Notes |
|---|---|---|
| 8.0 pre-flight | 10 min | includes the stop-the-line boot-arg check |
| 8.1 rebuild | 0–25 min | **skip entirely if `uname -r` is unchanged** — verify srcversion instead, it took seconds |
| 8.2 QEMU suite | **60–90 min** | + 20–40 min of solo re-runs for vng false FAILs (§2.4) |
| 8.3 dkms tooling | 5 min | reliable |
| 8.4–8.6 | 60–90 min | GPU-dependent; unmeasured on a qualifying card |

Two traps that between them cost ~40 min on 2026-08-06 and are now avoidable
by reading §2.6 (boot args) and §2.7 (suite logging) **before** starting.
Read those two first; they are the difference between a half-day and a
morning.

### 8.0 Pre-flight (10 min)

```bash
cd /home/mykola/linux-meshstor
uname -r                                                                 # 7.0.0-29-generic
# STOP-THE-LINE CHECK -- must print BOTH. If it does not, you booted the wrong
# GRUB entry and §8.4-8.6 will produce quietly wrong results (§2.6). Fix by
# rebooting into `ubuntu-meshstor`; do not proceed and do not "work around" it.
cat /proc/cmdline | tr ' ' '\n' | grep -E 'multipath|iommu'              # nvme_core.multipath=N + iommu=pt
cat /sys/module/nvme_core/parameters/multipath                           # N
cat /sys/kernel/iommu_groups/*/type | sort | uniq -c                     # identity (not DMA-FQ)
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

**The A2000's exact failure signature (re-confirmed 2026-08-06)** — if the new
card reproduces this, it does not clear the §3 BAR1 gate either:

```
cufio-cuda:745  Failed to get cuda p2p device address for ptr ... errornum: 801
cufio-drv:107   gpu attribute pci_p2pdma not supported errornum: 801  CUDA_ERROR_NOT_SUPPORTED
cufio-drv:156   Not all GPUs support PCIP2PDMA
cufio-drv:1274  Reset all P2P flags to 0
cufio-drv:1155  nvidia-fs.ko driver not loaded
```

Read that order carefully: cuFile rejects p2pdma **first**, then falls back to
nvidia-fs and fails because it isn't built. `gdscheck -p` therefore prints only
*"nvidia-fs driver is not loaded"* on the console, which is a **downstream
symptom, not the cause** — do not go build nvidia-fs (§4) thinking it will
unblock the native path. The `801` line in the DEBUG log is the real verdict,
so `logging.level=DEBUG` is mandatory here.

A qualifying card should show no `801` at all. Cross-check against the
hardware gate in the same breath: `nvidia-smi -q -d MEMORY | grep -A3 BAR1`
must report BAR1 Total **greater** than VRAM (the A2000 reports 8192 MiB BAR1
against 12282 MiB VRAM, and its ReBAR `supported:` list tops out at 8GB —
structurally impossible, §3).

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

### 8.2 QEMU p2pdma suite — real p2pdma pages, GPU-independent (60–90 min)

```bash
SP=<scratchpad>; mkdir -p $SP/msmods $SP/logs $SP/vmtmp
for m in ms_mod raid1_ms raid10_ms; do sudo zstd -dqf /var/lib/dkms/meshstor-ms/0.1.0/$(uname -r)/x86_64/module/$m.ko.zst -o $SP/msmods/$m.ko; done
make -C .worktrees/p2pdma/tools/testing/selftests/md/p2pdma/modules   # injector for THIS kernel
```

**Do not run `run_all.sh` with its stdout redirected to a file — you will get an
empty file and no results (§2.7).** Drive the same loop with a wrapper that
pipes each test and appends per-test verdicts, and use a 600 s timeout from the
start (§2.4). Write this to `$SP/run_suite.sh`:

```bash
#!/usr/bin/env bash
set -u
cd "${SUITE_DIR:?}" || exit 2
LOG=${LOG:?}; : > "$LOG.rc"
pass=0 fail=0 skip=0
for t in ${TESTS:-test_*.sh}; do
	[ -e "$t" ] || continue
	printf '=== %s ===\n' "$t" >> "$LOG"
	# PIPE, never a regular file: a regular-file stdout is inherited into
	# vng/virtme-run, which truncates it as the VM console (§2.7).
	timeout --kill-after=30 "${P2P_TEST_TIMEOUT:-600}" bash "$t" 2>&1 | tee -a "$LOG" >/dev/null
	rc=${PIPESTATUS[0]}
	printf '%s\trc=%s\n' "$t" "$rc" >> "$LOG.rc"
	case $rc in 0) pass=$((pass+1));; 4) skip=$((skip+1));; *) fail=$((fail+1));; esac
done
printf -- '--- p2pdma selftests: pass=%s fail=%s skip=%s ---\n' "$pass" "$fail" "$skip" >> "$LOG"
```

```bash
sudo env MD_SUBSYS=ms MS_MOD_DIR=$SP/msmods MDADM=/home/mykola/mdadm/mdadm TMPDIR=$SP/vmtmp \
     SUITE_DIR=$PWD/.worktrees/p2pdma/tools/testing/selftests/md/p2pdma LOG=$SP/logs/suite.log \
     bash $SP/run_suite.sh
# live progress, from another shell:
cat $SP/logs/suite.log.rc ; tr -d '\000' < $SP/logs/suite.log | tail
```

Baseline: **18 pass / 0 fail / 1 skip** (the skip is `route_fence_el10`).
Budget ~60–90 min at 600 s, not the 30 min originally written here — vng
retries dominate. Keep `LOG` **outside** `TMPDIR`, and `tr -d '\000'` the log
(VM serial padding).

Then re-run every failure solo before believing any of it (§2.4) — same
wrapper, adding `TESTS="test_a.sh test_b.sh"`. On 2026-08-06 that took two
passes: four cleared on the first solo re-run, and `stop_clean_after_p2p_error`
needed a third, fully standalone attempt (it then printed
`PASS: array stopped clean after p2p-error write`). Its own
`timeout 15 mdadm --stop` bounds the thing it actually asserts, so a genuine
`writes_pending` leak fails fast with a message — a bare 600 s hang is the
harness, not the array.

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
- **`run_all.sh` should pipe each test's stdout rather than pass its own
  through.** As written, any redirection of the suite to a file loses
  everything (§2.7), because the inherited regular-file stdout is treated as
  the VM console by virtme-run. The one-line fix is
  `bash "$t" 2>&1 | tee -a "$LOG" >/dev/null` with `rc=${PIPESTATUS[0]}`; the
  §8.2 wrapper does this externally so the suite source stays untouched on the
  `p2pdma` feature branch. Its default `P2P_TEST_TIMEOUT` should also be 600,
  not 300 (§2.4).
- **`run_all.sh` prints no progress and no per-test verdict file.** A 60–90 min
  run is opaque, and a killed run yields nothing at all. The §8.2 wrapper's
  `$LOG.rc` (one `name<TAB>rc=N` line per test, appended and closed each time)
  is what makes a long run observable and a partial run salvageable.

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

- **All pushes/sends are Mykola's, manually.** Stage commands, never run them
  (check the actual divergence with `git rev-list --count
  origin/gds-campaign..gds-campaign`; the count in §4 goes stale).
- This runbook is tracked (`docs/gds-ai-pc-rerun-runbook.md`); the
  `docs/superpowers/` archive is gitignored and now only holds a pointer to it.
- Tear down every VM/array/target you start (§2.5).
- Assessment ≠ authorization: discovered blockers are findings to report, not
  work orders.
