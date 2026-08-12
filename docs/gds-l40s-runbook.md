# GDS L40S window runbook (p2pdma campaign)

Copy-paste procedure for the few-hours hardware window. Deep context, expected
results per phase, and the full debugging playbook live in
`docs/gds-l40s-agent-briefing.md` — hand that file to an assisting model.
Every block below is paste-able as-is; run everything **from the kit root**
(`cd /opt/gds-kit-0.2.0`) as a sudo-capable user.

## Before the window (dev machine)

```bash
bash tools/testing/selftests/md/p2pdma/gds/test_unit_helpers.sh   # want: PASS: unit helpers
sudo bash tools/testing/selftests/md/p2pdma/gds/test_injector_smoke.sh  # resolver+filter smoke
bin/gds-make-kit 0.2.0                       # -> build/gds-kit-0.2.0.tar.gz (3 variants + manifest)
sudo bin/gds-campaign --rehearsal --kit build/gds-kit-0.2.0   # P0-P6 green; P7a-e SKIP (no gdsio) — the injector smoke above is the GPU-free P7 check; P7g/h/f SKIP
scp build/gds-kit-0.2.0.tar.gz l40s:/opt/
```

**Build the kit on a box running the SAME kernel as the L40S target.** The kit
ships DKMS source tarballs and records per-variant `raid1_ms`/`raid10_ms`
srcversions in `kit-manifest.tsv`, computed on the build box. Those srcversions
fold in the build-time `feature_flags.h` — the `HAVE_*` capability probe that
runs against the build box's headers. On the target, DKMS rebuilds each variant
against the *target's* running kernel, so any kernel — or `HAVE_*` — delta shifts
the target's loaded srcversions away from the manifest, and the P0
`ms_module_identity` gate fails identity and FAILGATEs the whole run before a
single GPU I/O. **Pre-flight:** confirm `uname -r` matches on both boxes (e.g.
both `6.17.0-35`) before `gds-make-kit`.

If `bin/gds-make-kit` wedges during its internal `rebuild-main` (`git am`) on a
build box with `commit.gpgsign=true` and an unreachable ssh/gpg signing key,
disable signing for the build — `git config commit.gpgsign false` (or export
`GIT_CONFIG_PARAMETERS` / run with `-c commit.gpgsign=false`) — then re-run. The
kit's DKMS tarballs are content-only; signing has no bearing on them.

### Kit variants + identity manifest

| variant | source | role |
|---|---|---|
| **gdsM** | `origin/meshstor-main` (SHA in manifest; `9478967d` at design time) | **featured/default install** — the shipping composition, stage-1 fail-the-write included; every phase runs on it |
| gds1 | `master` + `p2pdma@0fb37cf5` (pinned, pre-fix) | P7e A/B contrast ONLY |
| gds0 | verbatim `master` | P5 baseline (upstream unconditional advertise) |

`kit-manifest.tsv` (kit root, copied beside the tarballs by install.sh) records
per-variant srcversions for `ms_mod`, `raid1_ms` AND `raid10_ms` — the stage-1
delta is invisible in `ms_mod`'s srcversion, so the campaign's
`ms_module_identity` gate compares the personality modules. A stale loaded
variant triggers a gdsM reinstall; parse rows with `bin/gds-kit-manifest
<manifest> <variant> ref|tarball|srcversions`. After ANY module swap:
`cat /sys/module/raid1_ms/srcversion` must equal the manifest row of the
variant you expect.

## On the box — step 0: sanity gates (do these FIRST; each can kill the window)

```bash
mokutil --sb-state                            # want: SecureBoot disabled
grep CONFIG_PCI_P2PDMA "/boot/config-$(uname -r)"   # want: =y  (else native P2P impossible — stop)
grep CONFIG_DEBUG_INFO_BTF "/boot/config-$(uname -r)"  # want: =y (bpftrace tools are BTF-only)
uname -r                                      # want: >= 6.11 (6.17-class expected)
modinfo -F license nvidia                     # want: GPL/MIT (OpenRM open module; proprietary = no native P2P)
cat /proc/driver/nvidia/version               # want: >= 595 on a >= 6.15 kernel (see driver gate below)
command -v bpftrace nvme fio gdsio gdscheck   # all must resolve (gds tools: CUDA 12.8+ package)
nvidia-smi topo -m                            # note which GPU has PIX/PXB (not SYS) to the test NVMe
                                              # (all-NODE is OK: host-bridge P2P confirmed working on SPR + iommu=pt)
grep -o 'iommu=pt' /proc/cmdline              # want: iommu=pt — else IOMMU translates DMA and native GDS FAILS (step 0c)
cat /sys/module/nvme_core/parameters/multipath  # want: N  (Y masks rdma-leg advertise + gates P7g/h)
TESTBDF=$(readlink -f /sys/block/nvme1n1/device | grep -o '0000:[0-9a-f:.]*' | tail -1)
cat /sys/bus/pci/devices/$TESTBDF/iommu_group/type  # want: identity (DMA/DMA-FQ = translation = native GDS blocked)
```

**Boot prerequisites (BOTH required — bake into the boot BEFORE the window; each is a
reboot):** `iommu=pt` (identity DMA domains — the NVIDIA GDS P2P path needs them on
**every** platform, AMD included; see step 0c) **and** `nvme_core.multipath=N` (else the
nvmet CMIC head-split hides the rdma leg's P2P advertise and P7g/h SKIP). Stage both in
one reboot — recipe in step 0c.

- Secure Boot **enabled** → enroll the DKMS MOK + reboot (`mokutil --import
  /var/lib/dkms/mok.pub`, or `bin/mok-enroll` from a git checkout), or disable SB.
- Missing distro tools: `sudo apt install -y dkms "linux-headers-$(uname -r)" bpftrace nvme-cli fio`.

### Step 0b: NVIDIA driver gate for kernel-native P2PDMA (found live on the L40S, 2026-07-02)

cuFile's kernel-native path needs the GPU BAR1 registered as kernel p2pdma
memory, which takes **both** of:

1. **Open driver >= 595 on >= 6.15 kernels.** 580.x's UVM requires free p2pdma
   pages at refcount 1, but kernel commit b7e282378773 (>= ~6.15) initializes
   them at 0 → `UVM_ALLOC_DEVICE_P2P` always fails `NV_ERR_INVALID_ARGUMENT`,
   cuFile logs "Failed to get cuda p2p device address ... CUDA_ERROR_INVALID_VALUE"
   and driver-open errors 5001. 595.71.05+ carries the fix
   (`set_page_count(page, 1)` in `alloc_device_p2p_mem`).
2. **Two RM regkeys** (static BAR1 + uncached BAR1 iomap — WC mapping blocks
   UVM's `pci_p2pdma_add_resource`):

```bash
printf 'options nvidia NVreg_RegistryDwords="RMForceStaticBar1=1;RmForceDisableIomapWC=1"\n' \
    | sudo tee /etc/modprobe.d/nvidia-gds-p2pdma.conf
sudo systemctl stop nvidia-dcgm nvidia-persistenced 2>/dev/null
sudo modprobe -r nvidia_drm nvidia_modeset nvidia_uvm nvidia && sudo modprobe nvidia nvidia_uvm nvidia_drm
sudo systemctl start nvidia-persistenced nvidia-dcgm 2>/dev/null
cat /sys/bus/pci/devices/0000:XX:00.0/p2pmem/size   # want: BAR1 size (e.g. 68719476736) per GPU
```

No `p2pmem/` dir after a CUDA context touches the GPU → the regkeys or the
driver version gate above is not met; P1 will fail with map_hits=0.

**Sourcing 595+ open when the repos lag (2026-07-07, shadecloud).** apt / the CUDA
repos for ubuntu2404 topped out at `nvidia-open-580`; 595 came from the **`.run`**
open installer:

```bash
# apt driver userspace first (toolkit + libcufile are separate pkgs and survive):
sudo apt-get -y remove cuda-drivers 'cuda-drivers-*' 'nvidia-*-570' 'libnvidia-*-570'
curl -fSLO https://us.download.nvidia.com/XFree86/Linux-x86_64/595.71.05/NVIDIA-Linux-x86_64-595.71.05.run
sudo sh NVIDIA-Linux-x86_64-595.71.05.run --silent --kernel-module-type=open --dkms --no-cc-version-check
modinfo -F license nvidia   # want: Dual MIT/GPL (open)
```

**DKMS `.config` gotcha (mainline/zabbly headers).** If the headers package ships no
`/lib/modules/$(uname -r)/build/.config`, both the meshstor and nvidia DKMS builds die
`cp: cannot stat '.config'` — fix once before install.sh:
`sudo cp /boot/config-$(uname -r) /lib/modules/$(uname -r)/build/.config`.

On **≥7.1** the nvme-rdma override's `BUILD_EXCLUSIVE` refusal from install.sh is
**expected and harmless** — stock nvme-rdma already carries the P2PDMA wiring
(`23528aa`), so the campaign runs on the stock module with rdma-leg P2P intact. Do
not chase that WARNING.

### Step 0c: IOMMU passthrough is a HARD prerequisite for native GDS (found live on shadecloud, 2026-07-07)

**`iommu=pt` is required on EVERY platform — including AMD EPYC — not just SPR.** The
kernel's `cpu_supports_p2pdma()` gate (Zen ≥ 0x17 passes unconditionally) is a *separate
layer* from the NVIDIA driver's DMA setup: even when the kernel would permit the P2P, if
the IOMMU is in **full-translation mode** the GDS path can't build the peer IOVA mapping
and native GDS fails. A box with no `iommu=pt` (default on this EPYC 9354) boots its
devices into **`DMA-FQ`** domains, and the whole GPU-native chain (P1/P2 + P7a/b/d/e)
FAILs while every GPU-independent phase still passes.

**The exact signature (so you recognize it in 30 seconds, not after a failed P1):**
- `cat /sys/bus/pci/devices/<nvme-or-gpu-bdf>/iommu_group/type` → **`DMA-FQ`** (want `identity`);
- dmesg floods with `NVRM: GPUn nvAssertFailedNoLog: Assertion failed: pIOVAS != NULL @ io_vaspace.c`;
- cufile.log shows GPUs `PCIP2PDMACapable:1` **statically** but at runtime
  `gpu attribute pci_p2pdma support: False` → `GPUDirect Storage not supported on current file`;
- P1 FAILs `map_hits=0 cmd_rc=1`.

**Do NOT use plain `gdscheck -p`'s `NVMe : compat` line as a signal — it is config-driven, not
a platform verdict.** It only mirrors the active cufile.json's `use_pci_p2pdma` flag, and the
shipped default sets that `false`, so `gdscheck -p` prints `NVMe/NVMeOF : compat` **even when
native GDS is fully working** (verified: post-fix, with P2 `p2p_bios=520`, `gdscheck -p` still
said `compat`). To use gdscheck as a real platform probe, point it at a strict config —
`CUFILE_ENV_PATH_JSON=<json-with-use_pci_p2pdma:true> gdscheck -p` — and want **`NVMe : p2pdma`**
(not `compat`). In the default `gdscheck -p`, the only load-bearing lines are the per-GPU
`supports GDS, IOMMU State: …` rows. The authoritative native-path proof is always the P1
witness (`map_hits>0`).

This is **not a tooling bug and not fixable at run time** — cuFile picks the P2P GPU by
*storage proximity* (the DMA faults on whichever GPU BAR is nearest the NVMe, regardless of
gdsio `-d`), all GPUs share the DMA-FQ default domain, and bound nvme/nvidia devices can't
be re-homed to identity domains live. The only fix is a reboot.

**Stage both boot params in one reboot (GRUB; verify BEFORE rebooting):**
```bash
sudo cp -a /etc/default/grub /etc/default/grub.bak-gds-$(date +%F-%H%M%S)
sudo sed -i 's/^GRUB_CMDLINE_LINUX=""$/GRUB_CMDLINE_LINUX="iommu=pt nvme_core.multipath=N"/' /etc/default/grub
echo 'options nvme_core multipath=N' | sudo tee /etc/modprobe.d/nvme-multipath.conf   # root-on-nvme: nvme_core loads from initramfs
sudo update-initramfs -u && sudo update-grub
# all three must hit:
sudo grep -c "vmlinuz-$(uname -r).*iommu=pt" /boot/grub/grub.cfg
sudo grep -c "vmlinuz-$(uname -r).*nvme_core.multipath=N" /boot/grub/grub.cfg
sudo lsinitramfs /boot/initrd.img-$(uname -r) | grep -c modprobe.d/nvme-multipath
# then: sudo reboot
# after reboot confirm the flip: /proc/cmdline has iommu=pt; iommu_group/type -> identity;
#   /sys/module/nvme_core/parameters/multipath -> N.  (Plain `gdscheck -p` STILL prints
#   NVMe: compat even when native works — it mirrors the default config, not the platform;
#   use CUFILE_ENV_PATH_JSON=<strict.json> gdscheck -p and want NVMe: p2pdma. Real proof = P1.)
```
(If `GRUB_CMDLINE_LINUX` is already non-empty, append inside the quotes instead of the
empty-string sed.) The regkey `p2pmem` is lazy — run `gdscheck -p` once post-reboot to
re-create it before P1.

## Step 1: install + partitions

```bash
tar xzf /opt/gds-kit-0.2.0.tar.gz -C /opt && cd /opt/gds-kit-0.2.0
sudo ./install.sh                             # featured (gdsM) + nvme-rdma override + udev rule + /usr/sbin/msadm + manifest
test -x /usr/sbin/msadm && echo msadm-ok      # install.sh now installs it; P0 gates on msadm_present
grep Personalities /proc/msstat               # want: [raid1] [raid10]
sudo bin/perf-make-test-partitions /dev/nvmeXnY    # 4K-LBA NVMe with trailing free space
ls /dev/disk/by-partlabel/*-meshstor-test-*   # want: >=2 labels (4, across two drives, for raid10 fabric)
```

**HARD pre-flight — labeled test partitions must NOT overlap a live array.**
A stale/mis-pointed partlabel can resolve to a disk that is already a member of
a live md array (on the dev box, `nvme1n1-meshstor-test-2` resolved to
`/dev/nvme0n1p4`, a **live `md0` root-RAID member**). A campaign phase that
creates an array on such a partition hits `EBUSY` at best and can disturb the
**root array** at worst. Before the first run, prove the labels are safe:

```bash
cat /proc/mdstat                              # note every live md member
lsblk -o NAME,PARTLABEL,MOUNTPOINT,FSTYPE     # map each *-meshstor-test-* label to its disk
for L in /dev/disk/by-partlabel/*-meshstor-test-*; do echo "$L -> $(readlink -f "$L")"; done
mdadm --detail /dev/md0 2>/dev/null           # (system mdadm) confirm none of the above are members
```

Any test label that resolves onto a live md/root member → **re-point or drop
that label** (`sudo bin/perf-make-test-partitions … --remove` then recreate on
truly-free space) before running the campaign. Do not proceed with an
overlapping label.

`install.sh` now also installs the **meshstor-nvme-rdma override**
(nvme-rdma + the 23528aa P2PDMA backport, overriding via /updates).
Look for one of: `OK: nvme-rdma P2PDMA override active (loaded)` (good),
`OK: nvme-rdma override installed (not loaded yet; ...)` (good — loads on
first fabric connect), or a `WARNING:` (different-build-still-loaded /
build-refused / tarball-unpack-failed — campaign still runs, on the STOCK
driver; P0 records which). Manual check:
`modinfo -F filename nvme_rdma` (expect a path under `.../updates/`) and
`cat /sys/module/nvme_rdma/srcversion` vs `modinfo -F srcversion nvme_rdma`
(equal = the override is the one actually running). Re-shipping changed
override source under the same version is NOT supported — bump the
package version.

## Step 2: verify gdsio's interface (the wrappers were written from docs, never run on a GPU box)

```bash
gdsio -h    # cross-check: -x 0 = GDS, -x 1 = POSIX/CPU, -I 1 write / 0 read, -V verify, -d = GPU index
```

If the installed gdsio's mode numbering or verify flag differs, fix ONLY
`gds_gdsio_write` / `gds_gdsio_readverify` in `selftests/p2pdma/gds/lib.sh`, then
re-run `bash selftests/p2pdma/gds/test_unit_helpers.sh` (want `PASS: unit helpers`).
Pick the `-d` GPU index with the tightest PCIe path to the NVMe (step 0's topo output).

## Step 3: the main run (p0–p7 in one invocation)

The module-qualified injector probe un-SKIPped p6 on root-on-md boxes, and
p7 installs/verifies its own raid0 spoof and removes it — including via an
EXIT trap on aborts. The campaign takes ownership of the spoof whenever p7
runs (overwriting any pre-installed rule) and removes it at exit, so manual
post-campaign steps that need it — steps 4 and 6 — must reinstall the rule
themselves.

**cuFile 1.15 gate (found live): cuFile registers files only on `MD_LEVEL=raid0`
arrays** — raid1/raid10 are refused in userspace ("RAID level not supported by
cuFile for RAID group"), *identically for in-tree kernel md*, so this is cuFile
policy, not the ms rename. For the kernel-path phases (p1/p2) to run natively,
install this TEST-ONLY override first, and remove it when done:

```bash
printf 'SUBSYSTEM=="block", KERNEL=="ms*", ENV{MD_LEVEL}="raid0"\n' \
    | sudo tee /run/udev/rules.d/64-ms-raid0-spoof.rules
sudo udevadm control --reload
# ... campaign ...
sudo rm -f /run/udev/rules.d/64-ms-raid0-spoof.rules && sudo udevadm control --reload
```

The spoof only lifts cuFile's userspace level policy; the kernel still performs
real raid1/raid10 mirroring, which the witness + leg-compare then prove
(L40S evidence: p2p_bios=520, map_hits=779, legs identical). `/run` placement
means it disappears on reboot. **Never ship it**: cuFile also derives member
checks from the level, and production behavior on a lied-to cuFile is untested
beyond these probes.

```bash
sudo MDADM=$PWD/bin/mdadm-ms GDS_KIT_DIR=$PWD bin/gds-campaign --results /root/gds-results
column -t -s $'\t' /root/gds-results/verdict.tsv 2>/dev/null || cat /root/gds-results/verdict.tsv
# exit 0 = green; 1 = a FAIL row; 5 = INCOMPLETE (a P7 SKIP outside the
# expected gate/hatch set on a GPU-present box — treat as RED: stage-1
# evidence is missing without an accepted reason)
```

**Forcing the transport:** the campaign auto-detects (`rdma`→`rxe`→`tcp`) and,
with an mlx5 HCA present-but-**link-down**, picks `rdma` and then SKIPs the
fabric phases "no RDMA-capable address". To force a substrate pass
`--transport tcp|rxe|rdma` on the campaign CLI — the `GDS_TRANSPORT` env var is
honored only by the **standalone** `test_*.sh` scripts, **not** by
`gds-campaign` (its `--transport` beats any env). e.g. to exercise the rdma
path on a down-ported box, create a soft-RoCE device
(`sudo rdma link add rxe0 type rxe netdev <up-iface>`) and run
`--transport rxe`.

The campaign continues past failures; it stops only on a node-heartbeat wedge
(exit 3). Read `verdict.tsv`, not just the exit code. Two **expected** oddities:

- **`merge_control` FAIL on fast NVMe.** Zero observable request merges occur
  even on a raw partition with *no md* and `mq-deadline` set (confirmed on
  PM9A3: requests dispatch before they can queue). Treat the FAIL as
  environment noise, not a p2pdma regression.
- **p5 restore check:** after p5, confirm the featured package is back —
  `dkms status | grep meshstor` must show `*.gdsM` (the featured variant is
  now **gdsM**, not `.gds1` — `.gds1` is the pre-fix A/B-contrast pin). If the
  campaign aborted with exit 3 during p5, the box is on the BASELINE (`.gds0`)
  module: rerun `sudo ./install.sh` before anything else.

## Step 4: cuFile RAID-classification probe (needs a mounted ms array — the tests stop theirs)

NB the campaign removed its own raid0 spoof at exit, so this step and step 6
must (re)install the rule themselves before expecting cuFile raid0 behavior:
`sudo mkdir -p /run/udev/rules.d && printf 'SUBSYSTEM=="block", KERNEL=="ms*", ENV{MD_LEVEL}="raid0"\n' | sudo tee /run/udev/rules.d/64-ms-raid0-spoof.rules && sudo udevadm control --reload`.

```bash
M0=$(ls /dev/disk/by-partlabel/*-meshstor-test-* | sed -n 1p)
M1=$(ls /dev/disk/by-partlabel/*-meshstor-test-* | sed -n 2p)
sudo $PWD/bin/mdadm-ms --create /dev/ms0 --level=1 --raid-devices=2 --metadata=1.2 \
     --homehost=any --assume-clean --bitmap=internal --bitmap-chunk=128M \
     --consistency-policy=bitmap --failfast --run "$M0" "$M1"
sudo mkfs.xfs -f -q /dev/ms0 && sudo mkdir -p /mnt/ms0 && sudo mount /dev/ms0 /mnt/ms0
sudo MSADM=$PWD/bin/mdadm-ms bin/probe-cufile-recognition /mnt/ms0 |& tee /root/gds-results/cufile-recognition.txt
sudo umount /mnt/ms0 && sudo $PWD/bin/mdadm-ms --stop /dev/ms0
```

Exit 0 = cuFile takes real GDS on `/dev/ms0` (L40S-confirmed: per-I/O TRACE
`p2p mode: 1 compat: 0`; cuFile never exec'd mdadm — it reads the udev DB and
sysfs only). Exit 1 = compat fallback; the kernel side may still be perfect
(the witness proves that). Failure ladder as diagnosed live (§4.6):

1. No `MD_*` properties on `/dev/ms0` → `/usr/sbin/msadm` missing (step 1) or
   rule not triggered (`sudo udevadm trigger --subsystem-match=block
   --action=change /dev/ms0; udevadm settle`).
2. `MD_LEVEL:raid1` present but "RAID level not supported by cuFile" →
   **cuFile 1.15 raid0-only policy** (libcufile contains exactly one level
   string, "raid0"; stock md raid1 is rejected identically). Needs the step-3
   spoof for kernel-path evidence; **escalate as a product finding** — CSI
   raid1/raid10 volumes cannot do cuFile-native GDS on this cuFile release.
3. "unknown NVMe transport type ... transport: tcp" → cuFile also rejects
   nvme-tcp RAID members in userspace (its own member-transport AND).

## Step 5: p6 — the stage-1 NARROWNESS proof (runs inside the main invocation)

The injector now binds module-qualified (`raid1_ms:raid1_end_write_request`),
so in-tree `raid1` being loaded — udev autoload or root-on-md — no longer
steals the probe; the old "own invocation" dance is gone. Want:
`p6 divergence PASS narrowness: injected=N rc=0 msstat=[UU] leg1=stale(A)
no-breadcrumb` — a plain-bio INVAL is still swallowed (upstream semantics)
AND the stage-1 arm did not fire ("no P2P path" absent). If p6 shows the
breadcrumb: the arm fired for a non-P2P bio — kernel bug, escalate, do not
loosen the test. Standalone rerun if needed:
`sudo MDADM=$PWD/bin/mdadm-ms GDS_KIT_DIR=$PWD bin/gds-campaign --phases p6 --results /root/gds-results`.
NB any rerun truncates `verdict.tsv` in the shared `--results` dir (it
describes that invocation only) — the earlier full table survives in
`campaign.log`.

## Step 5b: p7 — stage-1 fail-the-write on real GPU I/O (runs inside the main invocation)

What to expect in `verdict.tsv` (all on gdsM except P7e, which swaps to the
pre-fix gds1 for the A/B contrast and restores gdsM; CSI array shape, spoof
managed by the phase itself):

```
p7  spoof        PASS  behavioral: scratch ms array reports MD_LEVEL=raid0
p7  p7a          PASS  EINVAL surfaced injected=N [UU] badblocks-empty breadcrumb
p7  p7b          PASS  TARGET keyed: EINVAL surfaced injected=N [UU] badblocks-empty breadcrumb
p7  p7c_kernel   PASS  breadcrumb, [UU], badblocks-empty, injected=N, disarmed pre-convergence
p7  p7c_userspace PASS gdsio rc=0 (bounce retry) + per-leg sha convergence
                  (or SKIP "cuFile compat mode does not retry mid-IO errors" -> product escalation)
p7  p7d          PASS  raid10: EINVAL surfaced ... (or SKIP "fewer than 4 test partitions")
p7  p7g / p7h    PASS on cabled RoCE + multipath=N boot; else SKIP naming the exact gate
p7  p7e          PASS  gds1 contrast: injected=N p2p-witnessed rc=0 no-breadcrumb
p7  restore      PASS  gdsM restored after A/B contrast (srcversion re-asserted)
p7  p7f          PASS natural arm / SKIP (no cross-RC pair, userspace refusal, or whitelisted)
final spoof_removed / injector_unloaded  PASS
```

If the campaign aborts mid-p7 (exit 3): the EXIT trap already removed the
spoof and disarmed/unloaded the injector — verify with
`ls /run/udev/rules.d/64-ms-raid0-spoof.rules` (must be absent) and
`lsmod | grep inval_inject` (must be empty). If the abort happened between
the gds1 swap and the restore, the box is on the PRE-FIX module: run
`sudo ./install.sh` (installs gdsM) before trusting anything else.

P7a FAIL with rc=0 ⇒ the arm did not fire ⇒ check the variant:
`cat /sys/module/raid1_ms/srcversion` vs the gdsM manifest row.

P7c `p7c_kernel` **SKIP** "cuFile compat mode does not retry mid-IO errors" ⇒
lenient-mode cuFile skipped the native path entirely (witness p2p_bios==0 with
a clean kernel delta — no breadcrumb, no I/O error). This is the cuFile-policy
hatch, not a kernel bug: it is a whitelisted SKIP (does not escalate to
INCOMPLETE), banked as a product escalation. Do not chase a kernel bug. (A
broken arm that *did* attempt native still fails the breadcrumb assertion in
the p2p_bios>0 path → a real FAIL, so this SKIP cannot mask a kernel defect.)

## Step 6 (OPTIONAL, crash-riskiest — only after all evidence above is off-box): strict GDS write against the falsely-advertising BASELINE array

```bash
# the campaign removed its raid0 spoof at exit — reinstall it for this manual step
sudo mkdir -p /run/udev/rules.d
printf 'SUBSYSTEM=="block", KERNEL=="ms*", ENV{MD_LEVEL}="raid0"\n' \
    | sudo tee /run/udev/rules.d/64-ms-raid0-spoof.rules >/dev/null
sudo udevadm control --reload
# swap to baseline (featured install.sh put gdsM on the box; remove that first)
TB=$(ls $PWD/tarballs/*gds0*.dkms.tar.gz); TMP=$(mktemp -d); tar xzf "$TB" -C "$TMP"
VER=$(ls "$TMP" | sed 's/^meshstor-ms-//'); sudo cp -r "$TMP/meshstor-ms-$VER" /usr/src/
FEATURED=$(dkms status meshstor-ms 2>/dev/null | grep -o 'meshstor-ms/[^,:]*gdsM' | head -1)
sudo modprobe -r raid10_ms raid1_ms ms_mod
sudo dkms remove "${FEATURED:-meshstor-ms/0.2.0.gdsM}" --all; sudo dkms add "meshstor-ms/$VER" && sudo dkms install "meshstor-ms/$VER"
sudo modprobe ms_mod && sudo modprobe raid1_ms && sudo modprobe raid10_ms
# local + loopback-tcp array (the shape baseline FALSELY advertises)
M0=$(ls /dev/disk/by-partlabel/*-meshstor-test-* | sed -n 1p)
M1=$(ls /dev/disk/by-partlabel/*-meshstor-test-* | sed -n 2p)
sudo modprobe nvmet nvmet-tcp nvme-fabrics nvme-tcp
NQN="nqn.2025-12.io.meshstor:tcp:gdstest:$(hostname -s)"
SS=/sys/kernel/config/nvmet/subsystems/$NQN; PT=/sys/kernel/config/nvmet/ports/7431
sudo mkdir -p "$SS/namespaces/1" "$PT"
echo 1 | sudo tee "$SS/attr_allow_any_host" >/dev/null
echo -n "$M1" | sudo tee "$SS/namespaces/1/device_path" >/dev/null
echo 1 | sudo tee "$SS/namespaces/1/enable" >/dev/null
echo tcp | sudo tee "$PT/addr_trtype" >/dev/null; echo ipv4 | sudo tee "$PT/addr_adrfam" >/dev/null
echo 127.0.0.1 | sudo tee "$PT/addr_traddr" >/dev/null; echo 4420 | sudo tee "$PT/addr_trsvcid" >/dev/null
sudo ln -s "$SS" "$PT/subsystems/$NQN"
sudo nvme connect -t tcp -a 127.0.0.1 -s 4420 -n "$NQN" --nr-io-queues=16 \
     --keep-alive-tmo=1 --ctrl-loss-tmo=3 --reconnect-delay=1
sleep 2; REMOTE=""
for c in /sys/class/nvme/nvme*; do [ "$(cat "$c/subsysnqn" 2>/dev/null)" = "$NQN" ] \
     && REMOTE=/dev/$(ls "$c" | grep -m1 '^nvme[0-9]*n[0-9]*$'); done; echo "REMOTE=$REMOTE"
sudo $PWD/bin/mdadm-ms --create /dev/ms0 --level=1 --raid-devices=2 --metadata=1.2 \
     --homehost=any --assume-clean --bitmap=internal --bitmap-chunk=128M \
     --consistency-policy=bitmap --failfast --run "$M0" "$REMOTE"
sudo bin/ms-queue-features /dev/ms0        # want: ADVERTISED (that's the baseline bug being shown)
sudo mkfs.xfs -f -q /dev/ms0 && sudo mkdir -p /mnt/ms0 && sudo mount /dev/ms0 /mnt/ms0
# strict cufile + witnessed write
cat > /tmp/cufile-strict.json <<'JSON'
{ "logging": { "dir": "/tmp", "level": "TRACE" },
  "properties": { "use_pci_p2pdma": true, "allow_compat_mode": false },
  "fs": { "generic": { "posix_unaligned_writes": false },
          "block": { "nvme": {"use_pci_p2pdma": true}, "nvmeof": {"use_pci_p2pdma": true}, "raid": {"use_pci_p2pdma": true} } } }
JSON
sudo dmesg > /root/dmesg-before-p5manual.txt
sudo CUFILE_ENV_PATH_JSON=/tmp/cufile-strict.json bin/gds-p2p-witness -o /root/p5-witness.txt -- \
     gdsio -f /mnt/ms0/p5probe.bin -d 0 -w 4 -s 256M -i 1M -x 0 -I 1 |& tee /root/p5-manual.txt
sudo dmesg > /root/dmesg-after-p5manual.txt
# teardown + RESTORE FEATURED before anything else runs
sudo umount /mnt/ms0; sudo $PWD/bin/mdadm-ms --stop /dev/ms0
sudo nvme disconnect -n "$NQN"; sudo rm -f "$PT/subsystems/$NQN"; sudo rmdir "$PT"
echo 0 | sudo tee "$SS/namespaces/1/enable" >/dev/null; sudo rmdir "$SS/namespaces/1" "$SS"
sudo ./install.sh && dkms status | grep gdsM
sudo rm -f /run/udev/rules.d/64-ms-raid0-spoof.rules && sudo udevadm control --reload
```

Whatever happens (INVAL errors, works-but-slow, oops) **is** the finding — save
it verbatim. Never leave the box on baseline.

**Observed outcome on the L40S (2026-07-02, cuFile 1.15):** benign refusal.
Even with the step-3 level spoof in place, cuFile rejected the array in
userspace *before any kernel I/O* — "unknown NVMe transport type for device:
nvmeXnY transport: tcp" → "RAID member not supported" — witness all-zero,
dmesg clean. cuFile independently ANDs member transports, so the kernel
false-advertise is not reachable through cuFile file I/O on this stack; the
residual exposure is limited to non-cuFile p2pdma producers. Evidence:
`gds-results/p5-manual/`.

## Copy off the box (BEFORE the window ends)

```bash
tar czf /root/gds-evidence.tgz /root/gds-results /root/p5-*.txt /root/dmesg-*.txt 2>/dev/null
scp /root/gds-evidence.tgz <you>@<devbox>:/tmp/    # plus /var/log/kern.log if anything crashed
```

## Abort criteria

- **Node wedged** (heartbeat exit 3, D-state kthreads): copy evidence out,
  reboot, resume with `--phases pN,...`.
- **P1 FAIL** (box can't do native GDS at all): stop the GDS phases; save
  `gdscheck -p`, `nvidia-smi topo -m`, IOMMU/ACS state (p0 evidence) as the
  diagnosis bundle; spend the remaining time on P4/P6 (GPU-independent).

## What each phase proves

p1 = box does native GDS (witness-calibrated); p2 = **headline** — GDS-native on
ms raid1, kernel-witnessed, both legs identical; p3 = CSI fabric topology +
whether an nvme-rdma leg advertises P2P; p4 = member-AND + hot-add-clear +
rdma-leg advertise gate (P4c) + Layer-B non-P2P regressions; p5 =
upstream-baseline falsely advertises with a tcp leg (justifies the fork's
member-AND); p6 = **stage-1 narrowness** — a non-P2P INVAL keeps upstream
swallow semantics and the arm does NOT fire (no breadcrumb); p7 = **stage-1
fail-the-write on real GPU I/O** — p7a/b the era-keyed arm (INVAL/TARGET ⇒
EINVAL loud, no fault, no badblocks, breadcrumb), p7c compat convergence
(production posture), p7d raid10 parity, p7e A/B contrast on pre-fix gds1
(old silent swallow, no breadcrumb), p7g/h native RDMA both-legs + any-leg
fallback (gated), p7f opportunistic natural-arm topology; step 4's probe =
cuFile actually classifies `/dev/msN` as RAID and takes the real P2P path.

Where each piece of stage-1 evidence can be produced: p7a–e = dev box
(rehearsal) AND the L40S target (the module-qualified probe made root-on-md
boxes injectable — the same fix un-SKIPped p6 there); p7g/h = only a box
with cabled hardware RoCE, the nvme-rdma override, and a
`nvme_core.multipath=N` boot; p7f = only a box whose test NVMe pair spans
root complexes.

P4c expectations (do not "fix" a PASS-refusal):

| nvme-rdma driver | substrate | expected |
|---|---|---|
| any, multipath=Y boot | any | PASS "multipath head masks leg advertise" — the head split hides the feature from the probed node; not a driver problem |
| stock (<7.1) | any | PASS "does not advertise" — install the override for hw runs |
| override | rxe/siw | PASS "refusal is correct" — `ib_uses_virt_dma` ⇒ no P2P, by design |
| override | real HCA, multipath=N | leg advertises AND the raid1 array advertises (member-AND positive) — the post-cabling headline |

NB the two rxe notes measure different axes: P3's `rxe substrate:
UNREPRESENTATIVE` is about the GPU-witness (rxe can't prove the native
P2P data path); P4c's `refusal is correct` is about block-layer
advertise correctness. An rxe run is meaningless for the former and a
valid PASS for the latter.

## L40S 2026-07-02 outcome snapshot (gpu-cluster-manassas, 6.17.0-35, nvidia 595.71.05)

All of the above achieved except two hardware impossibilities on that box:
P3 real-RoCE (mlx5 ports uncabled; answered on rxe, labeled UNREPRESENTATIVE:
nvme-rdma loopback leg does NOT advertise on 6.17) and — **as of that
2026-07-02 run** — P6 (root fs on in-tree md RAID1 → `raid1.ko` unremovable →
the then-current kprobe-ambiguity guard SKIPped; dev-box repro of the old
bug was injected=64). **SINCE RETIRED:** the module-qualified injector probe
(`raid1_ms:raid1_end_write_request`) removed that guard, so P6 — now the
stage-1 *narrowness* proof, not a bug repro — runs on root-on-md boxes too;
expect `p6 divergence PASS narrowness: …` on the next window.
P2 kernel-witnessed under the step-3 spoof:
p2p_bios=520 / map_hits=779 / legs identical; recognition probe rc=0.
Standing product escalations: (1) cuFile 1.15 is raid0-only — CSI raid1/raid10
volumes cannot do cuFile-native GDS without an NVIDIA-side change or a
level-presentation shim; (2) kit install.sh must install `/usr/sbin/msadm`.
Full chain of custody: `FINDINGS.md` inside the evidence tarball.

**2026-07-03 addendum — Finding E rdma half root-caused, twice over.**
The nvme-rdma leg's `remote=0` had TWO independent maskers: (1) stock
6.17 lacks `23528aa3320a` ("nvme: enable PCI P2PDMA support for RDMA
transport", first in v7.1-rc2) — fixed by the meshstor-nvme-rdma
override the kit now installs; (2) the native-multipath head split —
nvmet advertises CMIC, so on a `nvme_core.multipath=Y` boot (default)
the probed/consumed `/dev/nvmeXnY` is the head gendisk, and
`BLK_FEAT_PCI_P2PDMA` is set only on the hidden path disk and is not in
`BLK_FEAT_INHERIT_MASK` (unchanged through v7.1). The override removes
masker 1 only. On rxe the expected result stays negative regardless
(virt-DMA refusal — correct; verified live on the dev box 2026-07-03:
head features=0x10093 vs member 0x11093, bit 12 masked).

**2026-07-04 stage-1 increment rehearsal (dev box — no GPU / no gdsio,
rxe-only, root-on-md0).** Pre-hardware-window evidence that the campaign
changes themselves work; this box is NOT the L40S, so the full GPU-path
(P7a–e) and array-advertise (P3–P5) evidence stays the hardware window's job.
Rootless unit suite PASS; dkms tooling suite 11 PASS / 1 SKIP
(`test_patches_apply_clean` = all 11 patches, `--fuzz=0`, no reject;
`test_0008` P2PDMA pipeline green against a `meshstor-main` tree). Injector
smoke PASS — module-qualified resolver (`raid1_ms:raid1_end_write_request`)
fired with the in-tree `raid1` co-loaded, plain-INVAL swallowed `[UU]`,
`p2p_only=1` filtered to injected=0, bare-symbol `match=success` refused at
insmod. P6 narrowness PASS **live on the shipping gdsM module** ("non-P2P
INVAL swallowed … no breadcrumb, injected=64"). Kit 0.2.0 rebuilt clean:
gds0 / gds1@0fb37cf5 / gdsM@origin/meshstor-main + `kit-manifest.tsv` with
gds1≠gdsM personality srcversions (raid1_ms 8CAE1CC…≠9FF565A…, the stage-1
delta). Safe-scope rehearsal `--phases p0,p1,p2,p7` — exit 0, box left on
gdsM (loaded raid1_ms srcversion == gdsM manifest row): p0 all PASS/INFO
(`CONFIG_PCI_P2PDMA=y`, bpftrace, nvme-rdma override active, gdsM reinstalled
over the stale per-bucket variant, `/usr/sbin/msadm` present, transport
rxe = virt-DMA, `nvme_core.multipath=Y`); p1/p2 and every P7 subtest
(p7a–h, p7e, p7f) SKIP `gdsio not found` — on a no-gdsio box that one gate
fires **ahead** of the rxe / fewer-than-4-partitions / cross-RC gates, so
those per-subtest reasons only surface on a gdsio-equipped box; p7 A/B
restore PASS; final spoof/injector checks clean. Array-advertise phases
p3/p4/p5 were logic-verified only (NOT run live): the box's auto-picker
resolves member #2 to the stale partlabel `nvme1n1-meshstor-test-2`
→ `/dev/nvme0n1p4`, a LIVE md0 member, and those phases zero-superblock
their members — the smoke and P6 were instead funneled through a free-member
guard (`nvme1n1p1` + `nvme2n1p1`, both off the md0 disk). md0 verified
`[UU]` before and after every step.

**2026-07-07 (L40S gpu-cluster-manassas, 6.17.0-35, cuFile 1.15.1 / GDS
1.15.1.6, nvidia 595.71.05).** Full GPU-path campaign reproduced green after
one tooling fix: the witness grepped only stderr for bpftrace's `Attaching…`
banner, but bpftrace 0.20.2 emits it on **stdout**, so every GPU-witnessed
phase falsely SKIPped "witness could not attach" (fixed on `gds-campaign`:
grep both streams). Post-fix: P1 native PASS (control map=0 / native map>0),
**P2 headline p2p_bios=520 legs identical**, P7a/P7b/P7c_kernel/**P7d raid10
`[UUUU]`**/P7e A/B all PASS; P4a/P4b/P6-narrowness PASS; P5 baseline
false-advertise PASS. Then **rebooted with `nvme_core.multipath=N`** and, with
the mlx5 ports still uncabled (link-DOWN), created a soft-RoCE device
(`rdma link add rxe0 type rxe netdev bond0`) and ran the rdma gates: **P4c
rdma_gate PASS "override+virt-DMA: refusal is correct (ib_uses_virt_dma)"** —
the first reading with BOTH removable maskers gone (multipath head split +
missing override), isolating the residual non-advertisement to the by-design
virt-DMA refusal and closing the 2026-07-03 two-masker root-cause. P3 raid1 +
raid10 fabric (rdma/rxe) PASS (advertise_consistency `array=0==AND`, Finding E
`local=1 remote=0`, compat-fallback clean, legs consistent); nvme-rdma override
confirmed as the running module during the rdma connect (srcversion match).
Still gated on cabling: P7g/h native both-legs and P4c **positive** member-AND
(rxe is virt-DMA, UNREPRESENTATIVE for the native data path). Standing product
escalation refined: `p7c_userspace` is **not** a 1.15 artifact — the mid-IO
(execution-time) compat non-retry is an open NVIDIA Known Issue through cuFile
**r1.18** (briefing §4.6a 4th finding); only stage-2 self-heal closes it
in-house.

Later the same day `nvme0n1` was freed from the (now degraded, single-disk
`nvme1n1`) root arrays and repartitioned into test partitions — it sits on a
DIFFERENT root complex (`pci0000:00`) from nvme2n1/nvme3n1 (`pci0000:48`), so
**P7f finally had a genuine cross-RC pair and ran**: the strict native write on
the asymmetric raid1 (`nvme0n1`×`nvme2n1`) **succeeded** on both legs (witness
`p2p_bios=520 map_hits=777 rc=0`) → `P7f SKIP "platform whitelists cross-RC
P2P — witnessed native success, never a FAIL"`. Correct outcome on the
whitelisted SPR host bridge (§3.2): the natural stage-1 arm only fires where
cross-RC P2P is *refused*; a witnessed success is a SKIP, not a FAIL. This also
independently re-confirms host-bridge P2P across root complexes on this box.
(NB the root arrays are left degraded — restore redundancy after the window by
reclaiming nvme0n1 from the test partitions.)

## shadecloud 2026-07-07 — second L40S box, newer stack, provisioned green

Provisioning bank (environment readiness, **not** a full results run): `shadecloud`,
**AMD EPYC 9354 (Zen 4)**, kernel **`7.1.3-zabbly+`**, 8× L40S, **NVIDIA open
595.71.05**, **cuFile 1.18.1.6 / GDS 1.18** (upgraded from the toolkit's 1.13),
meshstor **gdsM** 3-variant kit built + installed. Every hard gate green:
`CONFIG_PCI_P2PDMA=y`, BTF, Secure Boot off, bpftrace attaches `submit_bio` +
`__pci_p2pdma_update_state`, patched mdadm, 4 test partitions (all on `nvme1n1`),
no root-on-md. **p2pmem `= 64 GiB` on all 8 GPUs** (BAR1 registered — the gate the
580-driver Manassas box failed). meshstor **and** nvidia-open both compile on 7.1.3;
`/proc/msstat = [raid1] [raid10]`; P0 all PASS incl. `ms_module_identity` (loaded
`raid1_ms` srcversion == gdsM manifest row). **Zen 4 passes the *kernel* platform P2P
gate unconditionally** — but that is NOT sufficient (see the full-run correction below).
The witness's `folio→pgmap` cast + enum resolve unchanged on 7.1 (§7 briefing);
full P1 calibration (native `map>0`) pends the `iommu=pt` reboot. Still gated on
hardware: cross-RC P7f (single-disk test partitions — no root-complex-spanning pair)
and cabled-RoCE P7g/h (`nvme_core.multipath=Y`, no cabled HCA). cuFile 1.18 makes the
`p7c_userspace` SKIP the vendor-acknowledged Known-Issue path, not a version artifact.

**Diagnostic run #1 (shadecloud 2026-07-07, PRE-FIX): 26 PASS / 8 SKIP / 13 FAIL — no
shipped-feature regression; native GDS blocked, root-caused to TWO independent causes.**
Every GPU-independent shipped-feature assertion was already green (P6 narrowness, P3
fabric on a *real cabled mlx5 HCA*, P4b, P4c, P5). The GPU-native FAILs (P1/P2 + P7a/b/d/e,
all `p2p_bios=0`, the arm never exercised — **not** stage-1 regressions) traced to:
1. **IOMMU translation.** The box booted without `iommu=pt` (devices in `DMA-FQ` domains);
   `NVRM ... pIOVAS != NULL`. Fixed by the reboot (→ `identity` domains, §3.2 / step 0c).
2. **A cufile.json schema bug in the harness.** `gds_cufile_json` nested `block` under `fs`,
   so cuFile ignored `block.nvme.use_pci_p2pdma=true` and bounced through compat
   (`gpu attribute pci_p2pdma support: False` even though driver-open logs
   `checkIfAllGPUsSupportP2PDMA=1`). Fixed by hoisting `block` to a top-level sibling
   (commit; briefing §4.6a + §8). **`iommu=pt` alone was necessary but NOT sufficient — both
   fixes were required.**
Plus a correction to the provisioning-bank prediction: **the P5/gds0 baseline false-advertise
DOES reproduce on 7.1** (baseline array advertised bit 12, `features=0x5090`, with a tcp leg —
7.1's `blk_stack_limits` did not self-AND it away; the fork's member-AND is still doing real work).

**Definitive run (shadecloud 2026-07-07, POST-FIX = iommu=pt reboot + cufile.json fix):
48 PASS / 6 SKIP / 9 INFO / 1 FAIL — full green** (the lone FAIL is the documented benign
`merge_control` fast-NVMe noise, §6). Native GDS proven end-to-end: **P1 calibrated, P2
headline `p2p_bios=520` legs bit-identical, P3 native on the real RDMA fabric
(`p2p_bios=518` raid1 / `8192` raid10).** `multipath=N` + the cabled mlx5 HCA delivered the
firsts Manassas never could:
- **Finding-E flipped to `remote=1`** (the nvme-rdma loopback leg now advertises) → the
  **positive member-AND**: `advertise_consistency PASS array=1 == AND(members)`.
- **P7g PASS** — witnessed **native GPU write over [local, rdma] legs** (`p2p_bios=520`, legs
  identical): the first cabled-RoCE native P2P through an ms array.
- **P4c** — stock 7.1 nvme-rdma advertises P2P natively; the **meshstor-nvme-rdma override is
  unnecessary on ≥7.1** (confirmed live, not just predicted).
- **Stage-1 arm on real GPU I/O all PASS** — P7a/P7b/P7d (INVAL+TARGET, raid1+raid10 `[UUUU]`:
  loud EINVAL, no leg fault, no badblocks, breadcrumb), P7e A/B contrast (gds1 silent swallow
  reproduced, no breadcrumb), P7c/P7h kernel side PASS (userspace pair SKIP = the r1.18 mid-IO
  compat non-retry Known Issue), P7f cross-RC witnessed native (`p2p_bios=518`, correct SKIP —
  EPYC whitelists cross-RC). Box left clean on gdsM.

## Post-cabling procedure — the gated P7g/P7h window (first actions when the RoCE ports go live)

1. `sudo rdma link delete rxe0` — the stale soft-RoCE device P0
   auto-created would otherwise skew substrate classification and
   address selection toward virt-DMA.
2. Boot with `nvme_core.multipath=N`. **Verified recipe (2026-07-07,
   nvme_core is a module loaded from initramfs for a root-on-md box) —
   set it in BOTH places so it can't be missed, then confirm before reboot:**
   ```bash
   echo 'options nvme_core multipath=N' | sudo tee /etc/modprobe.d/nvme-multipath.conf
   sudo sed -i 's/^\(GRUB_CMDLINE_LINUX="[^"]*\)"/\1 nvme_core.multipath=N"/' /etc/default/grub
   sudo update-initramfs -u && sudo update-grub
   # verify BEFORE rebooting (both must hit):
   sudo lsinitramfs /boot/initrd.img-$(uname -r) | grep modprobe.d/nvme-multipath
   sudo grep -c "vmlinuz-$(uname -r).*nvme_core.multipath=N" /boot/grub/grub.cfg   # want >=1
   # after reboot: cat /sys/module/nvme_core/parameters/multipath  -> N
   ```
   P0 captures the value; P7g/h SKIP with "boot nvme_core.multipath=N and
   rerun" until this is done. Pre-window planning item — not discoverable
   mid-window. NB device naming changes (no head node), and the regkey
   `p2pmem` is lazy — run `gdscheck -p` once after reboot to re-create it.
   **Post-reboot rig hazard (auto-handled since 2026-07-07):** a reboot
   incrementally assembles leftover superblocks on the *test* partitions into
   stray inactive `/dev/mdN`, which renumbers the real root array (e.g.
   `md0`→`md127`, alarming but harmless) and holds the partitions EBUSY. P0
   now reaps any md array whose members are all `*-meshstor-test-*` and
   zero-superblocks them; if running phases standalone, do it by hand first
   (`mdadm --stop /dev/mdN` for the strays, then `mdadm --zero-superblock`
   each test partition — confirm root/boot stay on their nvme0/1 arrays).
3. Re-run `sudo ./install.sh` if the kit was refreshed (version bump
   required if override source changed). Modules are not auto-`modprobe`d on
   boot — `modprobe ms_mod raid1_ms raid10_ms` (or rerun install.sh) and
   confirm `grep Personalities /proc/msstat`.
4. Run the p4 rdma gate, then `--phases p0,p7`: P7g asserts a witnessed
   NATIVE write over [local, rdma] legs with both legs verified through
   the nvmet backing device, and P7h asserts the CPU/kernel bounce retry
   when either leg fails (fail-local + fail-remote sub-runs). A cuFile
   userspace refusal ("cuFile member-transport policy (rdma)") is a SKIP
   + product escalation, not a FAIL — the P5-manual precedent.

**P7g/h witness precondition (target-kernel).** The `map_hits` witness gates
on `--expect-map nonzero`, which needs the target kernel to expose the P2P
DMA-map path (`__pci_p2pdma_update_state` / `pci_p2pdma_*`) in bpftrace's
function list — confirm with
`bpftrace -l 'kprobe:pci_p2pdma_*' 'kprobe:__pci_p2pdma_update_state'`
(present on 6.17-class). A kernel that lacks these symbols would read
`map_hits=0` on a genuinely-native write and **false-FAIL** P7g/h — recalibrate
on P1 (native must read map>0) before trusting the RDMA rows.
