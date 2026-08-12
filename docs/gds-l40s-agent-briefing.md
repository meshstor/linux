# GDS on L40S — Agent Operator Briefing (feed this whole file to the assisting model)

You are assisting a hands-on test engineer running the **meshstor P2PDMA / GPUDirect-Storage
validation campaign** on a real **L40S GPU + NVMe** machine, **Ubuntu 24.04**, for a
**limited hardware window (a few hours)**. This document is your complete operating context.
Read it fully before acting. It tells you what the system is, what "correct" looks like for
every check, every hazard that has already been diagnosed, how to debug failures, and — most
importantly — **which failures you may fix and which you must never paper over.**

> **Prime directive.** The entire point of this campaign is *trustworthy evidence*. A test that
> passes for the wrong reason is far worse than a test that fails honestly. When in doubt,
> preserve the failure and diagnose it — never loosen an assertion to make it green.

---

## 0. TL;DR — what you're proving and the one-line goal

The meshstor `ms_*` RAID driver (a renamed fork of Linux MD) has a **P2PDMA feature**
that lets NVMe SSDs DMA **directly to/from L40S GPU memory** (GPUDirect Storage, "GDS native"),
bypassing CPU bounce buffers — across a topology of **local NVMe legs + remote NVMe-over-Fabrics
legs** (the MeshStor-CSI production shape). Your job: **prove GDS-native actually works through an
`ms` raid1/raid10 array, prove the per-member safety gating is correct, and prove the v6
P2PDMA completion-handling behavior** (P6 = its narrowness, P7 = the arm on real GPU I/O) — all with
kernel-level evidence, not just cuFile's self-reporting.

> **2026-07-29 rework, read this before anything below.** The `p2pdma` branch was rebuilt on
> upstream's own v6 P2PDMA completion-handling series (upstreamed `md_bio_is_p2pdma()` +
> `raid1_write_error()` + the R1BIO_P2PDMA/R10BIO_P2PDMA tag), with meshstor's per-member
> advertise gate, the `p2pdma_advertise=auto|always|never` policy knob, and the
> `p2pdma_status` diagnostics report layered on top (see `docs/admin.md`). **The old "stage-1
> fail-the-write" design this document was originally written against is GONE.** The new
> behavior: a P2P-tagged completion that cannot route is recorded as a **bad block**, the
> member is **not** faulted, **`WantReplacement` is not set**, and the **master write
> succeeds** off the surviving leg — the opposite of the old fail-loud design. Only past
> ~512 badblock entries does the member get faulted and the array degrade (loud in
> dmesg/`/proc/msstat`, silent to the application). This section-by-section pass updates the
> normative descriptions (what the feature does, what each phase proves); it does **not**
> rewrite the P6/P7 selftests under `tools/testing/selftests/md/p2pdma-vm/gds/`, which still
> assert the retired design and need a separate pass before their exact PASS strings can be
> trusted again — treat any exact tool-output string below that still reads "fails loud" /
> "no badblocks" / "breadcrumb" as **pre-rework and unverified against the current branch**,
> not as this document's current claim. Historical, dated run-log entries (e.g. "L40S
> 2026-07-02 outcome snapshot", "shadecloud 2026-07-07") are untouched — they are records of
> what was actually observed against the pre-rework module at the time and are not rewritten
> to match the new design.

Success = the `verdict.tsv` shows the headline phases PASS with the **kernel witness** confirming
GPU-BAR pages traversed the array and the NVMe took the P2P DMA path.

---

## 1. Background: the system under test

### 1.1 What meshstor-ms is
A Linux-kernel fork shipping `meshstor-ms` — a **parallel `ms_*` MD/RAID subsystem** as a DKMS
package. It coexists with the kernel's built-in `md_mod`; it does **not** replace it. Distinct
names throughout: modules `ms_mod` / `raid1_ms` / `raid10_ms`, devices `/dev/msN`, sysfs
`/sys/block/msN/ms/`, proc file `/proc/msstat` (mirrors `/proc/mdstat`), dynamic major ~252.
On-disk superblock format is **bit-identical to kernel md** (v1.2), so disks move between them.

You edit **upstream-named source** (`md.c`, `raid1.c`, `mddev`); a rename pass generates the
`ms_*` product at build time. For this campaign you do **not** touch `drivers/md` at all — all
work is test tooling on the `meshstor-harness` branch.

### 1.2 The P2PDMA feature being validated (4 shipped commits on branch `p2pdma`, composed into `meshstor-main@9478967d`)
PCI **P2PDMA** lets one PCIe device DMA to another's memory (NVMe ↔ GPU BAR) without bouncing
through host RAM. The block layer marks such bios and the queue advertises capability via the
`BLK_FEAT_PCI_P2PDMA` queue-limits feature (bit 12). It is deliberately **excluded** from
`BLK_FEAT_INHERIT_MASK`, so a stacking driver like md must set it **explicitly**.

The four commits (in `drivers/md`, already built into the loaded modules):

1. **Per-member advertise gate** — `raid1_can_advertise_p2pdma()` (in `raid1-10.c`, used by both
   raid1 and raid10): the array sets `BLK_FEAT_PCI_P2PDMA` **only when every non-faulty member's
   queue advertises it**. Upstream advertises unconditionally and relies on a 7.1-era
   `blk_stack_limits` member-AND that is **absent from every meshstor target kernel** — so md must
   do the AND itself. **(≥7.1 caveat — verified in source 2026-07-07 on `7.1.3-zabbly+`: on a
   7.1+ kernel that member-AND *is* present; `block/blk-settings.c` clears `BLK_FEAT_PCI_P2PDMA`
   in `blk_stack_limits` whenever a stacked member lacks it, so upstream self-ANDs and the fork's
   gate is redundant-but-harmless there. Consequence: on ≥7.1 the P5/gds0 baseline does NOT
   falsely advertise with a tcp leg — see §5/§6.)** *Why it matters:* md is a pure router that never touches the pages; each
   member NVMe maps them, so a member that can't map GPU pages must never be handed P2P I/O.
2. **Hot-add clear** — `raid1_p2pdma_clear_on_add()`: adding a **non-P2P** member to an
   advertising array clears the advertisement **before** the new member becomes write-eligible
   (raid1 + raid10, normal-add and replacement slots). Guards against the same stale-advertise
   hazard on `mdadm --add`.
3. **P2P bio hygiene** — `md_bio_is_p2pdma()`: `md_submit_bio` **preserves `REQ_NOMERGE`** for P2P
   bios (merging P2P bios from different pgmaps at the member queue would map later segments with
   the wrong bus address → silent DMA corruption), and `raid1_write_request` **excludes P2P bios
   from write-behind** (write-behind CPU-touches pages, illegal for MMIO GPU pages).
4. **v6 P2PDMA completion handling (REWORKED 2026-07-29, supersedes the old "stage-1
   fail-the-write" design described in earlier revisions of this doc)** — the branch was
   rebuilt on upstream's own v6 P2PDMA completion-handling series rather than carrying a
   meshstor-only completion arm. A P2P-tagged bio (`R1BIO_P2PDMA`/`R10BIO_P2PDMA`, renamed
   from the retired `R1BIO_P2P`/`R10BIO_P2P`) whose completion status means "no P2P path" —
   literal `BLK_STS_P2PDMA` on a kernel that can emit it, or `BLK_STS_INVAL`/`BLK_STS_TARGET`
   translated to it by the DKMS compat layer (`dkms/patches/0012`) on kernels that can't —
   is handled exactly like upstream's own topology-aware design: the failing range is
   recorded as a **bad block**, the member is **NOT faulted**, **`WantReplacement` is NOT
   set**, and the **master write still succeeds**, served off the surviving mirror leg(s).
   Past ~512 badblock entries `rdev_set_badblocks()` itself faults the member and the array
   degrades — loud in dmesg/`/proc/msstat`, silent to the application. Non-P2P INVAL keeps
   upstream's ordinary swallow semantics unchanged — P6 proves that narrowness. Two new
   meshstor-only pieces ride alongside: the `p2pdma_advertise=auto|always|never` module
   parameter (policy override for the per-member advertise gate) and the read-only
   `/sys/block/msN/ms/p2pdma_status` diagnostics report — see `docs/admin.md` for both.

Origin history (REWORKED 2026-07-29, supersedes the pre-rework hashes this doc used to cite):
the `p2pdma` branch was reset onto upstream `master`@`ef76f702` and rebuilt via `git am` of
upstream's OWN v6 P2PDMA completion-handling series (`178f2659`..`a80daaa9`, 7 patches — the
old md-commit hashes cited by earlier revisions of this doc, e.g. `9e2b65d6`/`0fb37cf5`, no
longer exist on this branch; the pre-rework tip is preserved only under the local tag
`p2pdma-prev6`), with meshstor's own value-add layered on top as `[MESHSTOR]`-tagged commits:
per-member advertise gate `cb9920c7` → the `p2pdma_advertise` policy knob `cef31e11` →
hot-add/remove re-evaluation `775a3c92` → per-member `p2pdma_status` diagnostics `d4511c61`
(a use-after-free + missing stop-time reset fixed in `0f9d543f`) → the array-level
`p2pdma_status` line `768b1c81` (current branch tip). `origin/meshstor-main`'s composition
picks up this new tip the next time `bin/rebuild-meshstor-main` runs — the kit's gdsM SHA
cited elsewhere in this document as `9478967d` is from BEFORE this rework and no longer
matches; treat every gdsM/gds1 SHA in the historical run logs below as pre-rework evidence,
not a live pin. The DKMS compat layer that lets pre-7.2 kernels build without a native
`BLK_STS_P2PDMA` status (`dkms/patches/0012`) lives on `gds-campaign`, not on this branch.

### 1.3 The advertise gate is coarser than per-I/O reachability — what P6 and P7 now prove
The advertise gate is **coarser than per-I/O reachability**: the real per-I/O check is
`pci_p2pdma_state()` in the DMA-map path, which returns **`BLK_STS_INVAL`** (or, translated by
the compat layer, literal `BLK_STS_P2PDMA`) when *this* GPU's pages can't map to *this* member.
**As of the 2026-07-29 v6 rework, this is handled exactly the way upstream's own design
handles it — NOT by failing the write loud.** The failing range is recorded as a bad block,
the member is not faulted, `WantReplacement` is not set, and the master write succeeds off the
surviving leg; only past ~512 badblock entries does the member get faulted and the array
degrade. (Earlier revisions of this document described a meshstor-only "stage-1 fail-the-write"
arm that failed such writes loud with no badblocks recorded — that design is retired; see
§1.2 item 4.)

- **P6 = narrowness proof.** It injects INVAL into plain (non-P2P) CPU writes; the swallow MUST
  still happen (rc=0, `[UU]`, stale leg) and the P2P-arm breadcrumb MUST be absent. This
  invariant is unchanged by the v6 rework — a P6 FAIL is a real regression in either direction.
- **P7 = the arm on real GPU I/O** (gdsM, CSI shape). **Caveat:** the P7a–h selftests under
  `tools/testing/selftests/md/p2pdma-vm/gds/` still assert the retired fail-loud design (they
  predate this rework and have not yet been rewritten), so treat their current PASS/FAIL
  behavior against a v6-built gdsM as unverified, not as evidence either way, until they are
  updated. Once updated, the expected shape per subtest is: P7a/b era keying (INVAL/TARGET on
  a P2P-tagged bio ⇒ badblocked, no fault, no `WantReplacement`, master write succeeds — NOT
  loud EINVAL), P7c `allow_compat_mode: true` production posture, P7d raid10 parity, P7e A/B
  contrast against the gds1 pin — **exact pin and behavior TBD** (§3.1's kit-variant caveat: the
  branch reset means no current commit cleanly represents "advertise gate present, v6
  completion handling absent"; the old pre-rework tip, `p2pdma-prev6`, still has a completion
  arm, just the retired fail-loud one, not "no arm at all"), P7g/h native RDMA
  both-legs + any-leg-fails (hardware-gated), P7f opportunistic natural arm on a cross-RC
  topology. The deferred self-heal design (in-driver CPU bounce on a P2P miss) remains future
  work, independent of this rework.

---

## 2. The MeshStor-CSI topology you are replicating

The campaign uses **bare scripts issuing the CSI's exact command shapes** (no Kubernetes). The
shapes were mapped from `~/meshstor-csi` and are baked into the test helpers:

- **Array create** (`gds_csi_mdadm_create` in `gds/lib.sh`):
  ```
  mdadm --create /dev/msN --level={1|10} --raid-devices=K \
        --metadata=1.2 --homehost=any --assume-clean \
        --bitmap=internal --bitmap-chunk=128M --consistency-policy=bitmap \
        --failfast [--chunk=64 --layout=n2 for raid10] --run <members...>
  ```
  No write-mostly / write-behind (both fabrics are symmetric-latency in CSI). Members are
  interleaved **local-first per mirror pair**.
- **Remote leg** = loopback NVMe-over-Fabrics on the single node (`gds_nvmet_export`): an `nvmet`
  configfs target exporting a local partition, connected back to self with the CSI's flags:
  ```
  nvme connect --transport {tcp:4420|rdma:4421} --nr-io-queues=16 \
       --keep-alive-tmo=1 --ctrl-loss-tmo=3 --reconnect-delay=1 \
       --nqn nqn.2025-12.io.meshstor:<tr>:gdstest:<host> --hostnqn ...
  ```
  (`--fast_io_fail_tmo` was dropped: nvme-cli 2.8 doesn't accept it. If the L40S box has a newer
  nvme-cli that does, adding it back is optional and cosmetic — it does **not** affect any
  advertise/gating assertion, which are timeout-independent queue-feature reads.)
- **Volumes**: XFS with `noatime,nodiratime,logbufs=8,logbsize=256k,inode64,noquota`.

**Transport reality (Finding E, empirically confirmed on the dev box):** `nvme-tcp` **never**
advertises `BLK_FEAT_PCI_P2PDMA` (it has no `supports_pci_p2pdma` ctrl op). Only `nvme-pci` and
`nvme-rdma` can. So:
- A **local NVMe leg** can advertise (it's nvme-pci) → confirmed on dev box (`features=0x11093`, bit 12 set).
- A **tcp remote leg** never advertises → an array containing one must NOT advertise (that's the
  member-AND test, P4a).
- Whether a **loopback nvme-rdma leg** advertises is the open question P3 answers on real RDMA
  hardware — **this is new empirical data the L40S window produces.** (rxe/soft-RoCE is software
  and can't genuinely DMA GPU MMIO, so an rxe leg is marked UNREPRESENTATIVE.)
  **ANSWERED (L40S 2026-07-02, rxe substrate only — the box's mlx5 ports were uncabled):
  an nvme-rdma loopback leg does NOT advertise on 6.17** (`local=1 remote=0`), member-AND held,
  raid1+raid10 PASS. The hardware-RoCE variant remains open for a box with cabled RDMA ports.
  **2026-07-03 update: root-caused twice over.** The rdma `remote=0` had TWO independent
  maskers: (1) stock 6.17 lacks `23528aa3320a` (the `supports_pci_p2pdma` wiring, first in
  v7.1-rc2) — fixed by the **meshstor-nvme-rdma override** the kit now ships and `install.sh`
  installs; (2) the nvme **multipath head split** — nvmet advertises CMIC, so on a
  `nvme_core.multipath=Y` boot (default) the probed node is the head gendisk and
  `BLK_FEAT_PCI_P2PDMA` never propagates to it (not in `BLK_FEAT_INHERIT_MASK`; needs a
  `nvme_core.multipath=N` boot — see the runbook's post-cabling procedure). rxe stays
  non-advertising by design regardless: `ib_uses_virt_dma()` ⇒
  `ib_dma_pci_p2p_dma_supported()` = false. The P4c gate + its expectations table encode all
  of this (§4.5, §5, §8).
  **ANSWERED POSITIVE (shadecloud 2026-07-07, real cabled mlx5 HCA + `nvme_core.multipath=N`
  + kernel 7.1.3): the nvme-rdma loopback leg DOES advertise — `local=1 remote=1`.** With both
  removable maskers gone (7.1 carries `23528aa3320a` natively, so the override is unnecessary;
  and `multipath=N` removes the head split so the feature reaches the consumed node), the leg
  advertises `BLK_FEAT_PCI_P2PDMA` and the array does too: `advertise_consistency array=1 ==
  AND(members)` — the **positive member-AND** (both members advertise ⇒ array advertises). P7g
  then did a witnessed **native** GPU write over [local, rdma] legs (`p2p_bios=520`, legs
  identical). This is the post-cabling headline the earlier windows could not produce (Manassas
  was rxe-only + `multipath=Y`). NB on **≥7.1** P4c reads `stock driver advertises — override
  unnecessary` (INFO): the meshstor-nvme-rdma override only matters on `<7.1` kernels.

**The `p2pdma_advertise=always` remedy (added by the 2026-07-29 v6 rework — a second option
alongside the boot parameter above).** Both maskers above are really one problem: a P2P-capable
path hidden behind a non-advertising gendisk. `nvme_core.multipath=N` fixes it by removing the
head split entirely. `ms_mod.p2pdma_advertise=always` fixes it a different way — by overriding
the array's per-member advertise decision — and is available on every kernel this package
targets, whether or not `multipath=N` was booted. **On RHEL 10 the two are NOT
interchangeable: `always` is the *only* remedy.** RHEL 10's `nvme_core` is
`CONFIG_NVME_MULTIPATH=y` with the runtime `multipath` parameter compiled out, so there is no
boot-parameter escape hatch there at all — an rdma namespace always gets a multipath head. On
Ubuntu both remedies work; boot `nvme_core.multipath=N` if you want every array's advertise
decision to keep reflecting real per-member capability, or set `p2pdma_advertise=always` if you
don't want to reboot. `always` is **host-wide** (every `ms` array on the box, not just the one
with the rdma leg) — see `docs/admin.md` before setting it on a host with any genuinely non-P2P
array. One related cosmetic note for RHEL 10 heads specifically: the patched nvme-rdma driver's
multipath I/O accounting is skipped for statuses returned directly from `queue_rq` (an upstream
nvme-multipath quirk, not introduced by this package), so expect multipath accounting oddities
for every unroutable P2P I/O there — harmless, but visible.

---

## 3. Environment expectations (dev-box ground truth — verify on the L40S)

The tooling was authored and rehearsed on a box with these values. The L40S box should match the
load-bearing ones (kernel ≥ 6.11, CONFIG_PCI_P2PDMA=y, BTF, bpftrace); the rest may differ.

| Thing | Dev-box value | L40S must-have |
|---|---|---|
| Kernel | `6.17.0-35-generic` | **≥ 6.11** (for `BLK_FEAT_PCI_P2PDMA`); the shipped p2pdma feature is compiled in only then. **≥7.1 verified 2026-07-07 (`7.1.3-zabbly+`, §7) — witness unchanged, but P5/gds0 baseline shifts (§5/§6 item 9)** |
| `CONFIG_PCI_P2PDMA` | `=y` | **`=y`** — else native P2P is impossible regardless of md (authoritative gate; P0 checks it) |
| `CONFIG_DEBUG_INFO_BTF` | `=y` | **`=y`** — the bpftrace tools are BTF-only (no DWARF) |
| bpftrace | v0.20.2 | present |
| nvme-cli | 2.8 | present (flag caveat above) |
| ms modules | `ms_mod`,`raid1_ms`,`raid10_ms` loaded; `dkms: meshstor-ms/0.2.0.gdsM` (featured) | install from kit (below) |
| `/proc/msstat` | `Personalities : [raid1] [raid10]` | same after modprobe |
| Secure Boot | off | **check `mokutil --sb-state` FIRST** — with SB enabled, unsigned DKMS modules are rejected at modprobe (`Key was rejected by service`). Enroll the DKMS MOK + reboot (`bin/mok-enroll` in the git checkout — **not shipped in the kit**; on a kit-only box use `mokutil --import /var/lib/dkms/mok.pub` or `…/shim/mok/…` per Ubuntu DKMS docs), or disable SB, **before** anything else — this alone can eat the window |
| GDS tools | **absent** on dev box | **`gdsio`+`gdscheck` REQUIRED on L40S** (CUDA 12.8+, NVIDIA **open** kernel module) — checked, not installed, by the kit |
| NVIDIA driver | n/a | **open driver ≥ 595 on ≥ 6.15 kernels** + two RM regkeys — see §3.2; 580.x cannot do kernel-native P2PDMA on 6.17 at all (UVM refcount bug) |
| mdadm | patched build at `/home/mykola/mdadm/mdadm` (kit: `bin/mdadm-ms`) | **required for ms arrays** — the stock/system mdadm **rejects `/dev/msN`** (unknown device names/major). Use the system mdadm only for in-tree `/dev/mdN` cleanup |

### 3.1 The kit (how to get the software onto the L40S box)
`build/gds-kit-0.2.0.tar.gz` (~1 MB) is self-contained. It ships **three** DKMS variants +
`kit-manifest.tsv` (per-variant `ms_mod`/`raid1_ms`/`raid10_ms` srcversions):
- **gdsM** (`*.gdsM`) — `origin/meshstor-main`, the shipping composition, incl. the v6
  P2PDMA completion handling (badblock-and-continue, §1.2 item 4 — NOT the retired
  stage-1 fail-the-write design). **This is the featured/default install; every phase runs
  on it.**
- **gds1** (`*.gds1`) — a pre-rework `p2pdma` pin. **P7e A/B contrast ONLY.** **Caveat
  (2026-07-29 rework):** the exact commit this pins to needs re-verifying against whatever
  `bin/gds-make-kit` next resolves it to — the branch reset means no commit on the *live*
  `p2pdma` branch today represents "advertise gate present, completion handling absent"; the
  `p2pdma-prev6` tag (the pre-rework tip) still carries the retired stage-1 fail-the-write
  arm, not "no arm at all". The commit that WAS the kit's old gds1 pin, `0fb37cf5`
  ("advertise gate present, no completion arm, genuinely silent-swallow" — the original,
  meaningful A/B partner) still exists as a git object (verified 2026-07-29: `git cat-file -t
  0fb37cf5` → `commit`) but is **dangling — contained in no branch or tag** — so it risks
  `git gc` pruning; re-tag it (`git tag gds1-pin 0fb37cf5`) before the next kit build relies
  on it. Until re-tagged and re-verified, treat P7e's exact assertions as unconfirmed.
- **gds0** (`*.gds0`) — verbatim `master` upstream baseline. **P5 baseline** (unconditional advertise).

Plus the nvme-rdma override (`tarballs/meshstor-nvme-rdma-<ver>.dkms.tar.gz`), the `bin/` tools,
the `gds/` selftests, the `inval-inject/` module source, the udev rule, `install.sh`, and the
runbook. `install.sh` installs the **featured gdsM** package, `/usr/sbin/msadm`, the udev rule,
the manifest, and best-effort-installs the nvme-rdma P2PDMA override — look for the OK/WARNING
line (WARNING = campaign runs on the STOCK driver; P0 records which). On the box:
```
tar xzf gds-kit-0.2.0.tar.gz && cd gds-kit-0.2.0
sudo ./install.sh                      # featured (gdsM) + /usr/sbin/msadm + nvme-rdma override + udev rule + manifest
test -x /usr/sbin/msadm && echo msadm-ok
sudo bin/perf-make-test-partitions /dev/nvmeXnY   # two (or 4) 25GiB GPT test partitions
sudo MDADM=$PWD/bin/mdadm-ms GDS_KIT_DIR=$PWD bin/gds-campaign --kit $PWD --results /root/gds-results
```
If you are instead working **from the git checkout** at `/home/mykola/linux-meshstor` (patched
mdadm at `/home/mykola/mdadm/mdadm`, modules already installed), you can run the selftests and
`bin/gds-campaign` directly without the kit (P5/P7e A/B swaps then SKIP — they need `--kit`).

**Resolved (was a live-found gap):** early kits installed the udev rule but NOT the
`/usr/sbin/msadm` binary the rule's `IMPORT{program}` runs, so `/dev/msN` got no `MD_*`
properties and cuFile failed "Unsupported block device: /dev/ms0". **`install.sh` now installs
`/usr/sbin/msadm`**, and P0 gates on `msadm_present`. If P0's `msadm_present` ever FAILs on an
old kit, install it by hand: `sudo install -m0755 bin/mdadm-ms /usr/sbin/msadm`.

### 3.2 NVIDIA driver enablement for kernel-native P2PDMA (all found live on the L40S)

cuFile's kernel-native path needs GPU BAR1 registered as kernel p2pdma memory
(UVM calls `pci_p2pdma_add_resource`). Three gates, in dependency order:

1. **Two RM regkeys, both required** (neither is in the GDS docs):
   `NVreg_RegistryDwords="RMForceStaticBar1=1;RmForceDisableIomapWC=1"`.
   Static BAR1 maps all of FB through BAR1 (needs BAR1 ≥ VRAM — resizable-BAR firmware);
   the WC key matters because RM's default write-combined BAR1 iomap makes UVM skip p2pdma
   page creation (comment in `uvm_pmm_gpu.c: uvm_pmm_gpu_device_p2p_init`). Persist in
   `/etc/modprobe.d/`, reload the nvidia stack (stop dcgm/persistenced first).
   **Success indicator:** `/sys/bus/pci/devices/<gpu>/p2pmem/size` == BAR1 size per GPU.
2. **Open driver ≥ 595 on ≥ 6.15 kernels.** Kernel commit b7e282378773 initializes free
   ZONE_DEVICE p2pdma pages at refcount 0; 580.x UVM's `pci_p2pdma_page_free()` demands 1,
   so `UVM_ALLOC_DEVICE_P2P` always returns `NV_ERR_INVALID_ARGUMENT` — cufile.log shows
   "Failed to get cuda p2p device address … CUDA_ERROR_INVALID_VALUE" then driver-open
   error 5001 under strict json. 595.71.05+ carries the fix (`set_page_count(page, 1)`).
   (With the regkeys missing the same probe fails with error **801 NOT_SUPPORTED** instead —
   the errornum distinguishes the two gates.)
   **Sourcing the driver on a fresh box (2026-07-07):** apt and the CUDA local/network repos may
   lag — ubuntu2404 maxed at `nvidia-open-580` when ≥595 was required — so 595 open came from the
   **`.run`** (`us.download.nvidia.com/XFree86/Linux-x86_64/595.71.05/…`,
   `sh …run --silent --kernel-module-type=open --dkms`). Purge any apt-installed nvidia *driver*
   userspace first (`apt remove 'nvidia-*-<branch>' cuda-drivers`) — it **preserves** the CUDA
   toolkit + `libcufile`, which are separate packages. Confirm the open module took:
   `modinfo -F license nvidia` = `Dual MIT/GPL`, then the p2pmem gate. (DKMS build gotcha on
   mainline/zabbly headers: if `/lib/modules/$(uname -r)/build/.config` is missing, both the
   meshstor and nvidia DKMS builds die `cp: cannot stat '.config'` — `cp /boot/config-$(uname -r)`
   into the build tree first.)
3. **cuFile userspace gates** — see §4.6a; the kernel being ready is necessary, not sufficient.

Everything above is the GPU-side chain; fabric-leg P2P advertisement is a second, independent
AND'd chain: a **real HCA** (rxe/siw are virt-DMA and refuse by design) + the
**meshstor-nvme-rdma override** on < 7.1 kernels (stock lacks the `supports_pci_p2pdma` wiring)
+ a **`nvme_core.multipath=N` boot** (the head split otherwise hides the feature from the
consumed node). This leg-side chain gates only the rdma leg's block-layer advertisement — see
§8's ladder and the runbook's post-cabling procedure.

Topology note: the L40S box has no PIX/PXB GPU↔NVMe pairing (every GPU behind its own root
port, NVMes on one host bridge), so NVMe↔GPU P2P must traverse the CPU root complex
(`PCI_P2PDMA_MAP_THRU_HOST_BRIDGE`). **The kernel (`drivers/pci/p2pdma.c`) permits that ONLY
when `cpu_supports_p2pdma()` (AMD Zen, family ≥ 0x17 — always true) OR `host_bridge_whitelist()`
(Intel *server* host bridges only: Sandy/Haswell/Sky Lake-E, Ice Lake/SPR, Granite Rapids;
mainstream *desktop* Intel is NOT listed → P2P refused with `MAP_NOT_SUPPORTED`).** Verified from
source 2026-07-06 — this is a platform gate *below* the GPU, independent of the NVIDIA driver
gates. For the two candidate L40S CPUs:
- **AMD EPYC 9334 / 9354 (Zen 4)** — passes the *kernel* gate unconditionally via
  `cpu_supports_p2pdma()`; no whitelist/topology dependency. **But that gate is NOT
  sufficient — the NVIDIA driver still needs `iommu=pt` (see below); an EPYC box booted
  without it fails native GDS exactly like any other.**
- **Intel Xeon 8468 (Sapphire Rapids)** — whitelisted, but relies on the whitelist match AND
  needs `iommu=pt` (VT-d on, not `iommu=off`); confirmed working on the dev L40S
  (P1 map_hits=512). Slightly more fragile than the EPYC. **Empirically confirmed
  cross-RC on 2026-07-07 (P7f):** a real asymmetric raid1 spanning two root complexes
  (`nvme0n1`@`pci0000:00` × `nvme2n1`@`pci0000:48`) did a strict native write that
  *succeeded* on both legs (witness `p2p_bios=520 map_hits=777 rc=0`), so the stage-1
  natural arm correctly did NOT fire — the whitelisted host bridge permits cross-RC P2P
  exactly as the gate above predicts (P7f SKIP "platform whitelists cross-RC P2P", never
  a FAIL). The natural arm is reachable only on a non-whitelisted platform.
If P1 reads `map_hits=0` on a Zen/whitelisted-server platform with every NVIDIA gate satisfied,
the member NVMe's DMA-map is hitting `MAP_NOT_SUPPORTED` — see §8. (A consumer platform — desktop
Intel/AMD-APU — refuses this P2P outright regardless of GPU class or BAR1 size.)

**IOMMU passthrough is a fourth, platform-independent gate (shadecloud 2026-07-07, EPYC 9354).**
Distinct from the kernel `cpu_supports_p2pdma`/whitelist gate above: the NVIDIA GDS path builds a
peer **IOVA** mapping for the GPU BAR, and if the IOMMU runs in **full-translation mode** that
mapping can't be established, so native GDS fails *even though the kernel platform gate passes*.
A box booted without `iommu=pt` puts its devices in **`DMA-FQ`** default domains
(`cat /sys/bus/pci/devices/<bdf>/iommu_group/type`); the failure signature is dmesg
`NVRM: GPUn ... pIOVAS != NULL @ io_vaspace.c`, cufile.log `gpu attribute pci_p2pdma support:
False` despite static `PCIP2PDMACapable:1`, and P1 `map_hits=0 cmd_rc=1`. (Do **not** lean on
`gdscheck -p` here — its `NVMe : compat` line is config-driven, not a platform verdict; it reads
`compat` even when native GDS works. See the §8 note.) Not run-time fixable (cuFile selects the
P2P GPU by storage proximity, so
`-d` can't dodge it; bound devices can't be re-homed to `identity` domains live) — **boot
`iommu=pt`** (want `iommu_group/type` = `identity`). This bit shadecloud's whole GPU-native chain
while every GPU-independent phase still passed. Runbook step 0c has the staging recipe.

---

## 4. The tooling — component contracts

All bash tools: exit **0 = pass, 1 = fail, 4 = skip, 2 = usage**. Tests source
`tools/testing/selftests/md/p2pdma-vm/gds/lib.sh` (which sources the Layer-B
`../lib.sh`), use `trap`-based teardown, and default `MDADM=/home/mykola/mdadm/mdadm`
(override with `MDADM=` or the kit's `bin/mdadm-ms`).

### 4.1 `bin/ms-queue-features DEV [-q]` — the advertise-bit reader
There is **no sysfs** for `queue_limits.features`. This tool attaches a one-shot bpftrace kprobe to
the generic submit path (`submit_bio`/`submit_bio_noacct`/`…_nocheck`, first available) and fires
it with a tiny O_DIRECT read, printing the queue's feature word and testing bit 12.
- **Exit 0** = `BLK_FEAT_PCI_P2PDMA` advertised; **1** = not; **4** = cannot probe (SKIP); **2** = usage.
- Resolves a partition to its **whole disk** (the queue lives on the gendisk).
- Bit position is parsed from `blkdev.h` (matches both `BIT(N)` and `(1u << N)` idioms), fallback 12
  with a stderr warning.
- **Single observation primitive behind every gating assertion.** Trust its reading; a rc=4 means
  the probe couldn't fire, not "not advertised."

### 4.2 `bin/gds-p2p-witness [--expect-ms M] [--expect-map M] [-o FILE] -- CMD…` — the native-path witness
This is the **independent proof that CPU bounce buffers were bypassed**, because cuFile's own
"native vs compat" verdict is self-reported (and `gds_stats`/`/proc/driver/nvidia-fs/stats` only
cover the proprietary nvidia-fs path, not kernel-native p2pdma). It wraps a command under bpftrace
and counts:
- `p2p_bios` — bios entering `ms_submit_bio` whose first page is ZONE_DEVICE
  `MEMORY_DEVICE_PCI_P2PDMA` (**GPU BAR memory** — physically impossible after a CPU bounce).
- `host_bios` — other bios through `ms_submit_bio` (proves the probe fired at all).
- `map_hits` — calls into `pci_p2pdma_*` (the member DMA-map path; proves device-to-device mapping).
- Prints last line `p2p_bios=N host_bios=M map_hits=K cmd_rc=R`; `--expect-ms/--expect-map
  zero|nonzero|any` gate the exit. **Verdict rule: native run ⇒ both counters ≫ 0; compat/CPU run
  ⇒ exactly 0.** The two signals are AND-ed, and `map_hits` cannot be faked by a CPU bounce, so a
  native PASS can't be forged.
- **6.17-shaped** (folio→pgmap cast, enum value): a materially different kernel could miscount
  silently. It's for the L40S 6.17-class target; see §7 if the box differs.

### 4.3 `dkms/inval-inject/` — the status injector (TEST-ONLY kprobe module)
Plain kbuild module (never a dkms package, never ship). A kprobe on the **module-qualified**
`raid1_ms:raid1_end_write_request` (or `raid10_ms:raid10_end_write_request`) rewrites a matching
member's data-write completion status. Params: `disk=`, `partno=`, `match=ioerr|success|any`,
`to_status=inval|target|N`, `p2p_only=` (defaults: 0 for `match=ioerr`, 1 otherwise — MANDATORY
1 on mounted-fs rigs, XFS journal traffic traverses the probe), `remaining=` (arm), `injected=`
(ro). insmod REFUSES a bare `symbol=` in the live-traffic modes; in-tree `raid1` being loaded no
longer matters (the old mis-bind is what used to SKIP P6 on root-on-md boxes). Each test owns a
full insmod→arm→disarm→rmmod cycle; the campaign's EXIT trap force-disarms and unloads it on any
abort. See `dkms/inval-inject/README.md` for the interception-scope proof (bitmap/SB traffic
never reaches the probe) and the completion-time bvec P2P filter rationale.

### 4.4 `bin/gds-campaign [--rehearsal] [--phases LIST] [--transport auto|rdma|rxe|tcp] [--results DIR] [--kit DIR]`
The single orchestrator. Runs phases in **strict priority order**, writes an evidence tree
`results/gds-campaign-<ts>/<phase>/` with per-phase `.out` + `.dmesg` deltas and a cumulative
`verdict.tsv` (`phase<TAB>test<TAB>PASS|FAIL|SKIP|INFO<TAB>detail`). Node **heartbeat** between
phases (stops on a wedge, exit 3). **Exit codes: 0 = green; 1 = a FAIL row; 3 = node wedge;
5 = INCOMPLETE** — on a **GPU-present, non-rehearsal** box a P7 SKIP whose reason is *outside*
the enumerated hardware-gate / named-cuFile-policy-hatch set masks P2P-arm evidence and turns the
verdict INCOMPLETE (treat as red). Most SKIPs are still tolerated; only unexpected P7 SKIPs
escalate. `--rehearsal` = dev-box mode (skips GPU-only probes, never INCOMPLETE). Degradation:
auto-detects transport (real-rdma → rxe → tcp) and runs GPU-independent assertions even without
gdsio.

### 4.5 The selftests (also runnable standalone as `sudo bash <path>`)
| File | Phase | What it asserts |
|---|---|---|
| `test_gds_raw_baseline.sh` | P1 | GDS-native works on a **raw** NVMe partition; calibrates the witness (CPU control reads map=0, native reads map>0). Gate. |
| `test_gds_raid1_local.sh` | P2 | **Headline**: GDS-native on an ms raid1 (both legs local), witness confirms P2P pages + map hits through the array, both mirror legs hold identical correct data. |
| `test_gds_raid1_fabric.sh` | P3 | CSI topology: local + loopback NVMe-oF leg (tcp default, `GDS_TRANSPORT=rdma`, `GDS_RAID10=1` for 4-member raid10). Records the Finding-E rdma answer; asserts array advertise == AND(members); witnessed GDS when advertising, clean compat when not. |
| `test_gate_tcp_leg_no_advertise.sh` | P4a | Member-AND: a tcp (non-P2P) leg makes the array NOT advertise. |
| `test_gate_hotadd_clears.sh` | P4b | `clear_on_add`: hot-adding a non-P2P (loop) member to an advertising array clears the advertisement; removal alone preserves it (raid1 + raid10). |
| `test_gate_rdma_leg_advertise.sh` | P4c | driver×substrate×head-aware rdma-leg advertise gate; the PASS string is the evidence (head-masked / stock-no-op / virt-refusal-correct / override+hw positive incl. member-AND both-advertise). GPU-independent. |
| `test_divergence_inval.sh` | P6 | **Narrowness proof**: injected non-P2P INVAL keeps upstream swallow semantics (rc=0, `[UU]`, leg stale) AND the P2P completion arm does not fire (no breadcrumb); IOERR control correctly faults the leg. **(pre-rework wording; see the top-of-document note — the underlying test still asserts the retired design)** |
| `test_injector_smoke.sh` | — | GPU-free: module-qualified resolver fires with in-tree raid1 co-loaded; `p2p_only=1` filters plain writes to injected=0; bare-symbol refuse rule. |
| `test_p7a_inval_arm.sh` / `test_p7b_target_arm.sh` | P7a/b | P2P completion arm on real GPU I/O (INVAL / TARGET era keying). **(pre-rework wording; see the top-of-document note.)** Expected under the current design: badblocked, not faulted, no `WantReplacement`, master write succeeds — not "FAILS loud". |
| `test_p7c_compat_convergence.sh` | P7c | Production posture (`allow_compat_mode: true`): kernel side must PASS; userspace bounce-retry pair may SKIP "cuFile compat mode does not retry mid-IO errors" (NVIDIA-acknowledged Known Issue through cuFile r1.18 — see §4.6a 4th finding). |
| `test_p7d_raid10_arm.sh` | P7d | P7a on CSI raid10 via `raid10_ms:raid10_end_write_request`; SKIP "fewer than 4 test partitions". |
| `test_p7e_ab_contrast.sh` | P7e | A/B on gds1 (orchestrator swaps/restores): injected≥1 + witnessed P2P + rc=0 + NO breadcrumb, manifest-guarded. |
| `test_p7g_rdma_native.sh` / `test_p7h_rdma_leg_fail.sh` | P7g/h | Gated native RDMA both-legs / any-leg-fails-retries; SKIPs name the exact gate (transport, multipath=N boot, advertise, cuFile rdma policy). |
| `test_p7f_topology.sh` | P7f | Opportunistic cross-RC natural arm: PASS (EINVAL+breadcrumb+witnessed) / SKIP (userspace refusal or whitelisted platform) — never FAIL on witnessed success. |
| `test_unit_helpers.sh` | — | Rootless unit test + `bash -n` gate over every campaign file. Run after any edit. |

Env knobs the tests honor: `MDADM=` (patched mdadm path), `GDSIO=`/`GDSCHECK=` (tool paths;
default `/usr/local/cuda/gds/tools/…`), `GDS_RESULTS=` (evidence dir), `GDS_MNT=` (mountpoint,
default `/mnt/gds-test`), `GDS_TRANSPORT=tcp|rdma`, `GDS_RAID10=1`,
`GDS_PART_LIST="p1 p2 p3 p4"` (explicit members — **required, 4 entries, for the raid10 fabric
case**), `GDS_KIT_DIR=` (enables P5's A/B swap), `GDS_INJ_DIR=` (injector source override).

### 4.6 `bin/probe-cufile-recognition <mountpoint> [--md <ref-mnt>]` — the cuFile RAID-classification probe (L40S-only, run it!)
**The kernel queue flag is necessary but NOT sufficient.** cuFile does its own **userspace device
classification** via udev `MD_*` properties (and possibly by shelling out to mdadm). The
`md→ms` rename (`/dev/msN`, `/sys/block/msN/ms/`, `/proc/msstat`) can break that classification
even when the kernel side is perfect — cuFile then reports "cannot verify RAID members" and
**silently falls back to compat/bounce mode**. This was the single biggest open question motivating
the campaign, and it is only answerable with real GDS on the box.
- Run it against a **mounted ms array** (P2's array is ideal): `sudo bin/probe-cufile-recognition /mnt/gds-test`.
- It checks platform prereqs, the array/fs shape, the **udev DB `MD_LEVEL` property** for
  `/dev/msN` (installing `dkms/udev/63-ms-raid-arrays.rules` if missing — the rule needs `MSADM=`
  pointing at the patched mdadm), then drives a gdsio write under strace + TRACE-level cufile.log
  and greps for the real-P2PDMA vs compat verdict.
- **Exit 0** = real GDS confirmed; **1** = compat/no-GDS (classification failed — read section 5a
  of its output: did cuFile exec the SYSTEM mdadm, which rejects `/dev/ms*`? did it probe
  `/sys/block/msN/md/` instead of `.../ms/`?); **4** = SKIP.
- If it fails on classification while the witness proves the kernel path works on a raw partition,
  the fix space is: udev rule installed + triggered (`udevadm trigger --subsystem-match=block
  --action=change /dev/msN; udevadm settle`), `MSADM` env, or — if cuFile hard-codes `md`-named
  paths — record it as a **product finding** (escalate; may need a cuFile-side workaround or naming
  shim, not a test tweak).

### 4.6a ANSWERED on the L40S (2026-07-02, cuFile 1.15 / GDS 1.15.1.6) — the cuFile gate ladder

The open question resolved into **three distinct userspace gates**, in the order cuFile
evaluates them (each was hit, root-caused, and either fixed or worked around live):

1. **Classification works — via the udev DB only.** With `63-ms-raid-arrays.rules` active AND
   `/usr/sbin/msadm` present (§3.1 kit gap), `/dev/msN` carries full `MD_LEVEL`/`MD_DEVICE_*`
   properties and cuFile classifies it as RAID. strace confirmed cuFile **never execs mdadm**
   and never touches `/sys/block/msN/md/` — the udev-property half is the whole story, so the
   `ms` rename is fully compatible once the rule+binary are in place.
2. **cuFile 1.15 accepts `MD_LEVEL=raid0` ONLY — PRODUCT ESCALATION.** Registration on a raid1
   array fails `RAID level not supported by cuFile for RAID group : /dev/ms0 RAID : raid1`.
   Controls: `libcufile.so.1.15.1` contains exactly one level string (`raid0`), and an
   **in-tree kernel md raid1** control array is rejected with the identical error — this blocks
   cuFile-native GDS on raid1/raid10 for stock md too; it is NOT an ms issue. **Still present
   in cuFile 1.18.1 (shadecloud 2026-07-07): `libcufile.so.1.18.1` (and 1.13.1) carry the same
   lone `raid0` string — the raid0-only policy is unchanged 1.15→1.18, so the test-only level
   spoof is still required for kernel-path P2 evidence and the product escalation stands on the
   current release.** Consequence:
   MeshStor-CSI raid1/raid10 volumes cannot do cuFile-native GDS on this cuFile release without
   an NVIDIA-side change or a level-presentation shim.
   **Test-only workaround** used to produce the P2 kernel-path evidence: a `/run` udev override
   (`SUBSYSTEM=="block", KERNEL=="ms*", ENV{MD_LEVEL}="raid0"`) lifts the policy while the
   kernel still performs real raid1 mirroring — witnessed p2p_bios=520 / map_hits=779 with both
   legs bit-identical, and the recognition probe returned rc=0 with per-I/O TRACE
   `p2p mode: 1 compat: 0`. Remove the override after evidence runs; never ship it.
3. **cuFile rejects non-PCIe RAID members in userspace.** With a tcp leg in the array (even on
   the falsely-advertising baseline kernel), registration fails BEFORE any kernel I/O:
   `unknown NVMe transport type for device: nvmeXnY transport: tcp` → `RAID member not
   supported`. cuFile independently ANDs member transports — defense in depth that makes the
   kernel false-advertise unreachable via cuFile file I/O; residual exposure is limited to
   non-cuFile p2pdma producers (see the P5 manual-step outcome in §5).

Log-shape note: cuFile 1.15 writes `cufile_<pid>_<date>.log` (ignores the configured name's
tail) and its per-I/O native marker is `p2p mode: 1 compat: 0` at TRACE — the probe was fixed
live to parse both (commit on `gds-campaign`).

**4th cuFile finding (2026-07-07) — the compat-retry asymmetry P7c hits is NVIDIA-documented
through the LATEST release, not a 1.15 artifact.** P7c's userspace half presumes that when the
kernel fails a native P2P write mid-flight (`BLK_STS_INVAL`/EINVAL), cuFile catches it and
retries via CPU bounce so the app write still succeeds. It does not — gdsio returns rc≠0 and the
legs are not converged (the `p7c_userspace SKIP`). This is **not specific to cuFile 1.15**:
NVIDIA's GPUDirect Storage Release Notes list it as an **open Known Issue through r1.18** (the
current release as of this writing) — *"only I/Os that fail with -EOPNOTSUPP at submission time
are retried via the compat path by libcufile. I/Os that fail with this error during execution
time are not retried via the compat path."* Same architecture (submission-time-only compat
retry); the wording names GPFS/`-EOPNOTSUPP`, but the mechanism — libcufile never retries an I/O
that already failed mid-transfer — is general and unchanged across 1.15→1.18. So `p7c_userspace
SKIP` is **version-durable and vendor-acknowledged**: the meshstor P2P completion arm + array are
correct (`p7c_kernel` PASS), and the missing piece is a cuFile capability NVIDIA itself lists as
unfixed in the latest release. Upgrading cuFile does not change this; the only in-house path to a
transparent-convergence PASS is the deferred **stage-2 self-heal** (in-driver CPU bounce), not a
tooling tweak. Ref: `docs.nvidia.com/gpudirect-storage/release-notes` (r1.18 Known Issues).

**5th cuFile finding (2026-07-07, shadecloud) — the cufile.json `block` section must be a
TOP-LEVEL sibling, not nested under `fs`, or native P2P silently never arms.** cuFile's config
schema places `block` (with `nvme`/`nvmeof`/`raid` → `use_pci_p2pdma`) at the top level, beside
`properties` and `fs` (see the stock `/usr/local/cuda/gds/cufile.json`). The harness's
`gds_cufile_json` originally nested it under `fs`; cuFile **silently ignores the mis-nested
`fs.block`** and keeps the default `block.nvme.use_pci_p2pdma=false`, so every GDS write falls
back to compat even with `properties.use_pci_p2pdma=true` on a fully P2P-capable box. The tell is
a cufile.log where **driver-open confirms P2P** (`cufio-drv:160 ... checkIfAllGPUsSupportP2PDMA():
1`, `cuFileDriverOpen success`) yet **per-file registration fails** (`cufio-fs:882 p2p flags for
fs: xfs : 0`, `cufio-fs:891 gpu attribute pci_p2pdma support: False`, `cuFileHandleRegister
error: GPUDirect Storage not supported on current file`) — and the resolved config prints
`block.nvme.use_pci_p2pdma : false` despite the strict json. Fixed in `gds/lib.sh` (hoist `block`
to top level); verified by a manual witnessed write — **mis-nested ⇒ `map_hits=0 cmd_rc=1`;
top-level ⇒ `map_hits=512 cmd_rc=0`, GPUDirect verified.** This is orthogonal to `iommu=pt`: on
shadecloud BOTH the IOMMU passthrough boot AND this config fix were required before native GDS
worked. If a future window edits `gds_cufile_json`, keep `block` top-level.

---

## 5. Phase plan and the EXPECTED RESULTS MATRIX

Run priority order; highest-value/lowest-risk first. P5/P6/P7 last (they swap packages / inject
faults) — but all run in the **single default invocation** (`--phases` defaults to `p0..p7`).

| Phase | Command (from repo root, as root) | Expected on a healthy P2P-capable L40S | Expected if GPU/gdsio absent |
|---|---|---|---|
| **P0** | `bin/gds-campaign --phases p0` | `pci_p2pdma_config PASS`, `bpftrace PASS`, `modules PASS`, transport INFO, partitions INFO; GPU/OpenRM/gdscheck rows | same minus GPU rows |
| **P1** | `sudo bash …/test_gds_raw_baseline.sh` | PASS: control map=0, native map>0, read-verify ok | **SKIP rc=4** `gdsio not found` |
| **P2** | `sudo bash …/test_gds_raid1_local.sh` | PASS: advertise, witness p2p_bios>0 & map_hits>0, both legs identical | **SKIP rc=4** (before touching devices) |
| **P3 tcp** | `sudo GDS_TRANSPORT=tcp bash …/test_gds_raid1_fabric.sh` | INFO `local=1 remote=0`; `advertise_consistency PASS array=0`; advertise-only PASS | same (advertise logic is GPU-independent) → PASS |
| **P3 rdma** | `sudo GDS_TRANSPORT=rdma bash …/test_gds_raid1_fabric.sh` | INFO records whether rdma leg advertises (**new data**); if array advertises + gdsio: witnessed native PASS + leg integrity | SKIP if no RDMA NIC / no gdsio |
| **P4a** | `sudo bash …/test_gate_tcp_leg_no_advertise.sh` | PASS: local adv, tcp ns not, array not | PASS (GPU-independent) |
| **P4b** | `sudo bash …/test_gate_hotadd_clears.sh` | PASS: advertise → persist on remove → cleared on non-P2P add (raid1+raid10) | PASS (GPU-independent) |
| **P4c** | `sudo bash …/test_gate_rdma_leg_advertise.sh` | multipath=Y boot (today): PASS "multipath head masks leg advertise; driver=override substrate=…" — remedy is `nvme_core.multipath=N` **or** `ms_mod.p2pdma_advertise=always` (RHEL 10: `always` only, no runtime multipath toggle); post-cabling + multipath=N: PASS "override+hw: leg=adv array=adv (member-AND positive)". Any FAIL = real defect | same — GPU-independent; SKIP only if no RDMA-capable address |
| **P5** | `bin/gds-campaign --phases p5 --kit <dir>` | baseline swap: tcp-leg array **falsely** advertises (baseline has no member-AND) = expected finding; restore featured PASS. **On ≥7.1 kernels the false-advertise does NOT reproduce** — upstream's own `blk_stack_limits` member-AND clears it, so gds0 correctly non-advertises (expected, not a P5 regression; confirm with `ms-queue-features` per leg) | needs `--kit`; else SKIP |
| **P6** | `sudo bash …/test_divergence_inval.sh` | PASS: `non-P2P INVAL swallowed (narrowness proof) -- rc=0, [UU], leg1 stale, no breadcrumb (injected=N)` | PASS (loop substrate ok, GPU-independent; runs even with in-tree raid1 loaded) |
| **P7a/b** | `--phases p0,p7` (campaign manages the spoof) | **(pre-rework wording; see the top-of-document note.)** Expected under the current design: `P2P completion arm on raid1 (injected=N, badblocked, master write succeeds, no fault, no WantReplacement)` (b: TARGET) | SKIP rc=4 (gdsio absent) — INCOMPLETE on a GPU box |
| **P7c** | (same invocation) | kernel rows PASS; userspace PASS `compat convergence` or SKIP `cuFile compat mode does not retry mid-IO errors` (escalate to product — NVIDIA Known Issue thru r1.18, §4.6a) | SKIP |
| **P7d** | (same invocation) | PASS raid10 parity, or SKIP `fewer than 4 test partitions` | SKIP |
| **P7e** | (same invocation, kit required) | PASS: `gds1 A/B contrast — old silent swallow reproduced (injected=N, rc=0, no breadcrumb)`; `p7 restore PASS` after | SKIP (no kit) — INCOMPLETE on a GPU box |
| **P7g/h** | (same invocation) | cabled RoCE + override + multipath=N: PASS native both-legs / fail-leg retries; else SKIP naming the exact gate | SKIP |
| **P7f** | (same invocation) | PASS natural arm on cross-RC pair; SKIP otherwise (never FAIL on witnessed native success) | SKIP |

**Dev-box confirmed live (banked evidence):** P4a, P4b, P6 all PASS; P1/P2/P3-GDS SKIP (no gdsio);
P3 advertise-consistency PASS at raid1 + raid10 (tcp: `local=1 remote=0`, array=0). (The pre-fix
divergence repro that P6 used to be showed `injected=64`; P6 is now the narrowness proof and the
GPU-free P7 injector smoke covers the arm-side plumbing.) So on the L40S the **new** results are
P1/P2/P3-native (GPU), the full P7 arm-on-hardware set, the P3-rdma Finding-E answer, and the
cuFile-recognition verdict (§4.6).

**L40S confirmed live (2026-07-02, gpu-cluster-manassas, nvidia 595.71.05):** P0 PASS; P1 PASS
(control map=0 / native map_hits=512); P2 PASS **kernel-witnessed under the §4.6a level-spoof**
(p2p_bios=520, map_hits=779, legs identical) — without the spoof P2 FAILs at cuFile registration
(raid0-only policy), which is the expected shape on cuFile 1.15, not a regression; recognition
probe rc=0. P3 tcp raid1+raid10 PASS; P3 rdma answered on rxe (leg does not advertise); P4a/P4b
PASS; P5 PASS incl. the manual strict-gdsio step (benign userspace refusal, §4.6a gate 3);
P6 SKIPped on that box **at the time** (root fs on in-tree md RAID1 → `raid1.ko` unremovable →
the then-current kprobe-ambiguity guard). **That guard is now RETIRED** — the module-qualified
injector probe makes P6 (now the narrowness proof) and all of P7 producible on root-on-md targets;
a re-run expects `p6 divergence PASS narrowness: ...` there.

**Pacing for a few-hours window** (rough budgets): P0 ~10 min, P1 ~15, P2 ~20, P3 ~30, P4 ~30,
P5 ~20, P6 ~10, P7 remainder (P7a–e ~30 on a GPU box; P7g/h only in the cabled-RoCE window). Add
`probe-cufile-recognition` right after P2 (~10 min) while its array is still mounted. Evidence
flushes per-phase, so a truncated window still yields conclusions.

**Risk ordering is deliberate:** P5, P6 and P7 are last because they swap packages / inject faults
(P5's baseline swap, P7e's gds1 A/B swap, the P6/P7 status injection) — by then all shipped-commit
evidence is on disk. P5 also has an **optional manual step** (runbook §6): with the baseline
package installed and a tcp-leg array mounted, drive a **strict** gdsio write under the witness and
save dmesg — this is the single crash-riskiest action of the window; do it only after p0–p4
evidence is safely on disk, and expect anything from BLK_STS_INVAL errors to works-but-slow (P2P
pages have kernel vaddrs, so nvme-tcp's CPU copy may function with degraded performance). Whatever
happens **is** the finding — record it verbatim. After any P5 or P7e swap, verify the box is back
on the **featured gdsM** package: `dkms status` must show `*.gdsM` (NOT `*.gds1`, the pre-fix
contrast pin), and a fresh tcp-leg array must NOT advertise (member-AND is featured-only). If the
featured re-install fails, the campaign aborts loudly with exit 3 and the box is left on the
swapped-in variant — reinstall gdsM before trusting anything that runs afterwards.

---

## 6. PRE-DIAGNOSED HAZARDS (read before you debug anything — these are expected, not bugs)

These were hit and root-caused during development. **Do not "fix" the campaign in response to
these — handle them operationally as described.**

1. **(RETIRED) P6 used to SKIP when in-tree raid1 was loaded.** The injector now probes the
   module-qualified `raid1_ms:raid1_end_write_request`, so udev autoloading in-tree `raid1` (or
   root-on-md pinning it) no longer matters — P6 runs in the main invocation and on root-on-md
   boxes. If an injector test still reports a resolution SKIP, read the `gds_kallsyms_check`
   line in its `.out`: the module named there is missing/duplicated — that is a rig problem,
   not a reason to force-unload anything.

2. **`merge_control` FAIL on fast NVMe (any scheduler).** The Layer-B
   `test_nonp2p_merge_control.sh` (run under P4) asserts >0 member write-merges, but on fast
   NVMe there are **zero observable merges even on a raw device with no md at all and
   mq-deadline set** (confirmed on the dev box under `none`, re-confirmed on the L40S PM9A3s
   under `mq-deadline` — requests dispatch before they can queue).
   **→ This is NOT a p2pdma regression**; treat the FAIL as **expected environment noise**.
   It will flip the campaign's overall exit to 1; read `verdict.tsv`, don't trust exit code
   alone. (A real test bug was also fixed here on the L40S: `lsblk -no KNAME` can emit the ms0
   holder first while the array is active, making the test read the array's never-merging stat;
   the fix — `lsblk -dno KNAME` — is on `gds-campaign`.)

3. **Signing.** The branch history is committed `--no-gpg-sign` (no signing agent in the automated
   sessions). If you `git commit` here, use `-s --no-gpg-sign` unless the operator has a live
   signing agent. Commit identity is **`Mykola <mykola@meshstor.io>`** (author + `Signed-off-by`).

4. **cuFile false-pass trap.** Always run the **strict** cufile.json (`allow_compat_mode: false`)
   for native-path claims — otherwise a failed true-P2P silently bounces through CPU and cuFile
   still reports success. The witness (§4.2) is the real arbiter; if cuFile says "native" but the
   witness reads `map_hits=0`, **believe the witness** and record a FAIL.

5. **`ms-queue-features` rc=4 ≠ "not advertised".** rc=1 is "not advertised"; rc=4 is "couldn't
   probe" (SKIP). The hardened tests already branch three-ways. If you write new checks, do the
   same — never fold rc=4 into a boolean advertise flag.

6. **Loopback nvmet teardown / stale superblocks.** Members are zero-superblocked before create
   (post final-review fix), and `gds_nvmet_teardown` disarms incremental assembly + removes the
   configfs subsystem. If a run dies mid-way, see §8 recovery. (L40S addendum: the disarm can
   still *race* udev — the backing partition's superblock reappears on the fresh loopback
   namespace at connect time and incremental assembly grabs it into a stray `/dev/mdN` after
   the disarm already ran. Fixed on `gds-campaign`: `gds_nvmet_export` now zeroes backing
   superblocks BEFORE export and `udevadm settle`s after connect.)

7. **P2 FAILs at cuFile registration without the §4.6a level-spoof.** cuFile 1.15 accepts
   `MD_LEVEL=raid0` only; a raid1/raid10 array is refused in userspace before any kernel I/O.
   **→ Not a regression** — install the test-only `/run` udev override for the GDS-native
   phases and remove it after (§4.6a gate 2). The advertise assertion inside P2 is unaffected.

8. **(RETIRED) P6 on root-on-md boxes.** The module-qualified probe made the narrowness proof
   producible on the Manassas-class targets (root on in-tree md RAID1) — no guard to defeat,
   nothing to bank remotely. Expect `p6 divergence PASS narrowness: ...` there now.

9. **(≥7.1 kernels) baseline gds0 does NOT falsely advertise with a tcp leg.** On a 7.1+ target
   upstream's own `blk_stack_limits` performs the member-AND (`block/blk-settings.c` clears
   `BLK_FEAT_PCI_P2PDMA` when any stacked member lacks it), so the P5 "baseline falsely
   advertises" finding — and the very premise of the per-member gate (§1.2 item 1) — no longer
   applies. gds0 correctly non-advertising there is **expected, not a regression**; the fork's
   explicit gate is redundant-but-harmless. Confirm with `ms-queue-features` per leg rather than
   assuming the documented false-advertise. (On <7.1 targets the member-AND line is absent and P5
   reproduces as written — that is why the gate ships.)

---

## 7. PORTABILITY: what may silently misbehave if the L40S kernel ≠ 6.17-class

The bpftrace tools read kernel structs by BTF. If the L40S box runs a **materially different
kernel**, verify before trusting counts:

**Banked positive result (2026-07-07, shadecloud, kernel `7.1.3-zabbly+`):** the 7.1.x
portability check passed with **no tooling change** — `enum memory_type` still has
`MEMORY_DEVICE_PCI_P2PDMA == 5`, `include/linux/memremap.h` still reaches pgmap via
`folio->pgmap` (the witness's folio cast is correct), and `__pci_p2pdma_update_state` is a global
traceable symbol (the witness selects the precise map probe, not the glob fallback). Both the
meshstor DKMS modules and the NVIDIA **open 595.71.05** module compile clean against 7.1.3. Still
calibrate on P1 (control=0, native>0) before trusting P2/P3 counts. **But note the one ≥7.1
*behavioral* shift that is NOT a portability bug: upstream self-ANDs P2PDMA in `blk_stack_limits`,
so P5/gds0 no longer falsely advertises (§1.2 item 1, §5, §6 item 9).**
- **`gds-p2p-witness`** casts `bio->bi_io_vec->bv_page` **through `struct folio`** to reach
  `->pgmap` (6.17 moved `pgmap` out of `struct page` into the folio union) and uses
  `MEMORY_DEVICE_PCI_P2PDMA == 5`. On an **older** kernel where `struct page` still has a direct
  `->pgmap`, the folio cast reads the **wrong offset silently** (miscounts, no error).
  **→ Verify:** `pahole -C page $(which vmlinux || echo /sys/kernel/btf/vmlinux)` or check
  `include/linux/mm_types.h` for `page->pgmap` vs folio; and confirm the enum value in
  `include/linux/memremap.h` (`enum memory_type`, `MEMORY_DEVICE_PRIVATE = 1` … count to
  `PCI_P2PDMA`). If different, update the `.bt` program's cast/enum and re-run the P1 calibration
  (control must read 0, native must read >0) before trusting P2/P3.
- **`ms-queue-features`** self-parses the bit position from headers; fine across kernels, warns on
  fallback.
- **`inval-inject`** uses `bdev_partno()` (6.17 API). On older kernels it **fails to build** →
  the P6 test SKIPs cleanly (safe, not silent). If P6 must run there, adapt the accessor
  (`bio->bi_bdev->bd_partno` on older kernels) — it's a test-only module, no compat policy applies.
- The `map_hits` AND-signal protects P2/P3 headline verdicts even if `p2p_bios` miscounts, so a
  native PASS still can't be forged — but a `--expect-ms zero` control could false-FAIL. Recalibrate
  on P1 first.

---

## 8. DEBUGGING PLAYBOOK — symptom → likely cause → action

**General method:** reproduce with the **single standalone test** (not the whole campaign), read
its `.out` + `.dmesg` under `results/…/<phase>/`, and check the witness/queue-feature raw dumps.
Prefer `set -x` on the specific test over guessing. **Never edit a test to make it pass; edit only
to fix a genuine tooling bug, and re-run the unit gate + the affected live test after.**

| Symptom | Likely cause | Action |
|---|---|---|
| `modprobe ms_mod` → `Key was rejected by service` | **Secure Boot** rejecting the unsigned DKMS module | `mokutil --sb-state`; enroll a MOK (`bin/mok-enroll`) + reboot, or disable SB in firmware. Do this before anything else. |
| `mdadm: /dev/ms0` rejected / "unknown device" | using the **system** mdadm on an ms array | Use the patched mdadm (`MDADM=` / kit `bin/mdadm-ms`). System mdadm is only for in-tree `/dev/mdN` cleanup. |
| rdma leg doesn't advertise (P4c FAIL or unexpected refusal) | in order: multipath head split (expected on multipath=Y — not a driver problem); override not loaded; rxe/siw substrate (expected refusal); BUILD_EXCLUSIVE refused the build; IOMMU/ACS blocks `dma_pci_p2pdma_supported` | walk the ladder: `readlink /sys/class/block/nvmeXnY` contains `nvme-subsystem` ⇒ boot `nvme_core.multipath=N` **or** set `ms_mod.p2pdma_advertise=always` (RHEL 10: `always` is the *only* option — no runtime `multipath` parameter exists there); `/sys/module/nvme_rdma/srcversion` == `modinfo -F srcversion` + path under `.../updates/` ⇒ else reload; substrate rxe/siw ⇒ correct refusal (post-cabling: `rdma link delete rxe0` first); `dkms status` + install.sh WARNING; only then suspect IOMMU/ACS. NB built-in nvme-rdma shows `(builtin)` from modinfo (P0: built-in (not overridable)), not "absent" |
| P0 `pci_p2pdma_config FAIL` | kernel built without `CONFIG_PCI_P2PDMA=y` | **Stop** — native P2P is impossible on this kernel. Report; use a kernel with it =y. Not fixable in tooling. |
| gdsio errors on flags / unexpected `-x`/`-V` behavior | the wrappers' gdsio flags (`-d 0 -w 4 -s 256M -i 1M -x {0,1} -I {0,1} -V`) were written from docs, **never run against a real gdsio** | `gdsio -h` FIRST; if mode numbering or verify semantics differ, fix ONLY the two wrappers `gds_gdsio_write`/`gds_gdsio_readverify` in `gds/lib.sh` (they isolate this exact risk), re-run unit gate + P1. |
| cuFile refuses the file on an ms array (`Unsupported block device` / `RAID level not supported` / `RAID member not supported`) despite witness proving raw-partition native | one of cuFile's **three userspace gates** (§4.6a): missing `MD_*` props (msadm/rule), the **raid0-only level policy**, or a non-PCIe member transport | Walk the §4.6a ladder in order: `udevadm info --query=property /dev/msN | grep MD_` (empty → install `/usr/sbin/msadm` + trigger); `RAID level not supported` → expected on raid1/raid10, use the test-only level-spoof for kernel-path evidence + escalate as product finding; `unknown NVMe transport` → cuFile's own member AND, working as designed. |
| `ms-queue-features` always rc=4 | bpftrace can't attach; no BTF; probe symbol missing | `bpftrace -l 'kprobe:submit_bio*'`; check `CONFIG_DEBUG_INFO_BTF=y`; check `/sys/kernel/tracing/available_filter_functions`. Fix probe name if the submit path differs on this kernel. |
| P1 native `map_hits=0` (control also 0) | **First suspect: the NVIDIA driver gates (§3.2)** — regkeys missing (cufile errornum **801**) or 580.x-vs-≥6.15 UVM refcount bug (errornum **1** + driver-open 5001); then ACS/IOMMU; then topology; **then the kernel pci_p2pdma platform gate (§3.2 topology note)** | Check `/sys/bus/pci/devices/<gpu>/p2pmem/` exists; grep cufile.log for `errornum: 801` (→ regkeys) vs `errornum: 1` (→ driver < 595); `gdscheck -p`; `nvidia-smi topo -m` (all-NODE is fine on SPR+`iommu=pt` — confirmed). **If `p2pmem/` exists but map_hits still 0: FIRST check `cat /sys/bus/pci/devices/<bdf>/iommu_group/type` — `DMA-FQ`/`DMA` = IOMMU in translation mode ⇒ the NVIDIA GDS path can't build the peer IOVA (dmesg `pIOVAS != NULL @ io_vaspace.c`, cufile.log `pci_p2pdma support: False` despite static `PCIP2PDMACapable:1`) ⇒ boot `iommu=pt` (want `identity`; §3.2 IOMMU gate + runbook step 0c). This bites AMD EPYC too. **If `identity` already (e.g. after the `iommu=pt` reboot) but native STILL fails with a CLEAN dmesg (no `pIOVAS`): check the cufile.json `block` nesting (§4.6a 5th finding)** — cufile.log shows `checkIfAllGPUsSupportP2PDMA(): 1` at driver-open yet per-file `gpu attribute pci_p2pdma support: False` and `block.nvme.use_pci_p2pdma : false` despite the strict json; fix = `block` as a TOP-LEVEL section in `gds_cufile_json`, not under `fs`. Only once the config is correct AND the domain is `identity`: the member NVMe's DMA-map is likely `MAP_NOT_SUPPORTED` — the GPU↔NVMe path crosses the root complex and the platform isn't P2P-trusted. Confirm the platform passes the kernel gate: AMD Zen (`grep -q AMD /proc/cpuinfo` + family ≥ 0x17) OR a whitelisted Intel-server host bridge (`lspci -nns 00:00.0`; SPR ok, desktop Intel e.g. `0xa740` NOT). Neither ⇒ no GPU fixes it; need a Zen/server platform or a common PCIe switch.** If the box genuinely can't do native GDS, P1 is a legitimate FAIL — record it, fall back to advertise-only mode for P2–P4. |
| P2 witness `p2p_bios=0` but cuFile says native | cuFile bounced silently; or witness attach failed | Check witness `-o` dump: if `host_bios>0` the probe fired and cuFile really bounced (real FAIL — investigate cuFile/topology). If witness rc=4, it's a SKIP not FAIL. |
| `gdscheck -p` says `NVMe : compat` (or you expect it to say `Supported`/`p2pdma` and it doesn't) | **gdscheck's `NVMe/NVMeOF : compat`-vs-`p2pdma` line only echoes the ACTIVE cufile.json's `use_pci_p2pdma` flag** — the shipped default is `false`, so plain `gdscheck -p` prints `compat` **even when native GDS works** (confirmed shadecloud 2026-07-07: post-fix, with P2 `p2p_bios=520`, it still said `compat`). It is NOT a platform-capability verdict. | To probe the platform with gdscheck: `CUFILE_ENV_PATH_JSON=<json with use_pci_p2pdma:true> gdscheck -p` and want **`NVMe : p2pdma`**. In the default output the only load-bearing lines are the per-GPU `supports GDS, IOMMU State: …` rows. The authoritative native-path proof is the **P1 witness** (`map_hits>0`), never gdscheck's compat line. |
| P2/P3 witness `p2p_bios>0` on a **CPU** run (false positive) | pgmap union misread on wrong kernel (§7) | Recalibrate on P1 (control must be 0). If control ≠ 0, fix the folio/enum in `gds-p2p-witness` and re-verify. |
| P2 `advertise FAIL` intermittently | probe flake (rc=4 folded) — should already SKIP | Confirm you're on the post-fix tests (three-way rc). Re-run; a genuine `advertise FAIL` on an all-NVMe array = real member-AND regression (investigate the feature, not the test). |
| P3 array advertises with a **tcp** leg | member-AND regression **or** you're on the **baseline** (`*.gds0`) or **pre-fix** (`*.gds1`) package | `ms-queue-features` each member; `dkms status` (featured must be `*.gdsM`, not `*.gds0`/`*.gds1`); cross-check `cat /sys/module/raid1_ms/srcversion` vs the gdsM manifest row. If featured and it still advertises → real bug in `raid1_can_advertise_p2pdma`; capture and report. |
| P4b advertisement not cleared after non-P2P `--add` | `clear_on_add` regression, or add landed as spare and clear fires on activation | `mdadm --detail /dev/ms0`; re-read advertise after the member is truly active. If still advertising with an active non-P2P member → real bug. |
| P6/P7 FAIL "injector never fired" | module-qualified kprobe didn't bind; wrong module loaded; module build failed | check the test's `gds_kallsyms_check` output (`raid1_ms:raid1_end_write_request` must resolve exactly once); `dmesg` for insmod errors; rebuild `make -C dkms/inval-inject`; verify the variant srcversion against the manifest. |
| P6 shows the "no P2P path" breadcrumb | the P2P completion arm fired for a NON-P2P bio | **kernel bug — escalate, do not loosen the test.** |
| P7a fails with gdsio rc=0 | the arm did not fire → wrong module variant loaded (gds1/gds0 left behind), or injector mis-aimed | `cat /sys/module/raid1_ms/srcversion` vs the gdsM row of `kit-manifest.tsv`; re-run `sudo ./install.sh`; check `injected` count in the `.out`. |
| P7a/b/d/e all FAIL with `p2p_bios=0 ... cmd_rc=1` (gdsio rc≠0) | **downstream of a P1 FAIL — NOT a P2P-arm regression.** No native P2P write existed, so the arm was never exercised (it needs a real `R1BIO_P2PDMA`/`R10BIO_P2PDMA` bio). Whole-box native GDS is broken, not the fix. | Confirm it's downstream, not a real arm defect: the `.out` shows the injector resolved (`raid1_end_write_request in [raid1_ms]: 1 copies`) and `.dmesg` has **no `no P2P path` breadcrumb, no leg-fault, no badblocks** (arm didn't run). Fix P1 (usually the `iommu=pt` IOMMU gate, §3.2) and re-run — do **not** escalate as a P2P-arm regression. A real arm defect instead shows `p2p_bios>0` with the wrong completion behavior. |
| Campaign exit 5 (INCOMPLETE) | a P7 subtest SKIPped for a reason outside the expected gates/hatches on a GPU box | read the `INCOMPLETE:` log lines; fix the named rig condition and re-run `--phases p0,p7` (p0 refreshes env.sh — a p0-less run only inherits a previous run's values). Treat as red, not as a pass. |
| Node wedged, kthreads in D state | a real deadlock; or you ran with `MD_SUBSYS=md` | **Never set `MD_SUBSYS=md`** — the raid10 recovery-freeze test wedges in-tree kthreads (reboot to clear). Copy `results/` off, reboot, resume with `--phases`. |
| Array won't create ("device busy"/superblock) | stale superblock or udev grabbed the device | `mdadm --stop`; `mdadm --zero-superblock <dev>` (system mdadm for /dev/mdN, patched for members); `wipefs -a` as last resort on a **test** partition only. |
| Array create hits `EBUSY` on a labeled test partition | the `*-meshstor-test-*` label resolves onto a **live md/root array member** (seen on the dev box: `nvme1n1-meshstor-test-2` → `/dev/nvme0n1p4`, a live `md0` member) | **STOP — do the runbook's HARD pre-flight**: `cat /proc/mdstat`; `for L in /dev/disk/by-partlabel/*-meshstor-test-*; do echo "$L -> $(readlink -f "$L")"; done`; `mdadm --detail /dev/md0`. Re-point/drop the overlapping label (`perf-make-test-partitions … --remove` then recreate on free space) before any campaign phase. Never create on a live-array member. |

---

## 9. RULES OF ENGAGEMENT — what you may fix vs. must escalate

**You MAY fix (tooling bugs), then re-run the unit gate + affected live test:**
- bpftrace probe names / struct offsets that differ on this kernel (§7).
- nvme-cli flag spellings the local version rejects.
- sysfs path spellings (`/sys/block/ms0/ms/…`), scheduler tweaks, teardown-hygiene gaps.
- portability accessors in the test-only injector.
- Any crash/hang in the **test harness itself**.

**You MUST NOT do:**
- Loosen or delete an assertion to turn a FAIL green. A real regression must stay visible.
- Edit `drivers/md` / the shipped feature to make a test pass (that changes what's under test —
  escalate instead).
- Set `MD_SUBSYS=md` (wedges in-tree kthreads).
- Enable `allow_compat_mode: true` to launder a **native** pass (P1/P2/P7g). (P7c *deliberately*
  runs compat mode to test the production bounce-retry posture — a different assertion, not a
  native-path claim; its kernel-side arm rows still key on the breadcrumb, not on cuFile.)
- Push, force-push, or rewrite history without the operator saying so.

**ESCALATE to the operator (report clearly, don't guess) when:**
- A shipped-feature assertion genuinely FAILs (member-AND, clear_on_add, silent-divergence
  behavior changed) — this is a real finding, the whole point of the campaign.
- P1 can't do native GDS at all (topology/ACS/driver) — needs a human hardware call.
- P6 shows the P2P-arm breadcrumb, or any P7 kernel-side row FAILs (arm not firing / firing too
  wide / faulting a member for a routable transfer / mis-recording badblocks) — that is a real
  P2P-arm regression on the shipping
  composition, the single most valuable finding this campaign can produce.
- You're tempted to change what a test asserts.

---

## 10. Evidence to collect before the window closes

The deliverable is the **evidence tree**, not just green checks:
```
tar czf gds-evidence-$(date +%Y%m%d).tgz /root/gds-results   # (pass a real timestamp; don't rely on it in-script)
```
Plus, for the record: `nvidia-smi topo -m`, `lspci -tvnn`, ACS state, `gdscheck -p`, `dkms status`,
`uname -r`, and `dmesg` if anything crashed. Each phase dir already holds its cufile TRACE log,
gdsio output, witness dumps, `ms-queue-features` readings, `/proc/msstat`, `mdadm --detail/--examine`,
and a dmesg delta.

**Minimum win** (P0–P2): a kernel-witnessed "GDS-native works on ms raid1 with cross-leg integrity"
verdict + advertise-gating observations. **Target** (+P3–P4): fabric topology + the Finding-E rdma
answer + gating negatives. **Stretch** (+P5–P6): baseline false-advertise characterized + divergence
reproduced.

---

## 11. Key file locations (git checkout `/home/mykola/linux-meshstor`)

```
bin/gds-campaign                                  orchestrator
bin/ms-queue-features                             advertise-bit reader (bpftrace)
bin/gds-p2p-witness                               native-path witness (bpftrace)
bin/gds-make-kit                                  kit builder
bin/probe-cufile-recognition                      cuFile RAID-classification probe (§4.6)
bin/mok-enroll                                    MOK enrollment helper (git checkout only, not in kit)
tools/testing/selftests/md/p2pdma-vm/gds/            P0–P6 phase tests + the P7a–h P2P-arm subtests (pre-rework; need updating, see the top-of-document note) + injector smoke + lib.sh + unit test
tools/testing/selftests/md/p2pdma-vm/lib.sh          Layer-B helpers (sourced by gds/lib.sh)
tools/testing/selftests/md/p2pdma-vm/test_*.sh       Layer-B non-P2P regression suite (run under P4)
dkms/inval-inject/                                status injector + README (make -C to build)
dkms/udev/63-ms-raid-arrays.rules                 cuFile RAID-classification udev rule
docs/gds-l40s-runbook.md                          concise window runbook (procedure + abort)
build/gds-kit-0.2.0.tar.gz                        the scp-able kit (3 variants + manifest)
```
Design spec + implementation plan (deeper rationale, gitignored local archive):
`docs/superpowers/specs/2026-07-01-gds-l40s-p2pdma-campaign-design.md` and
`docs/superpowers/plans/2026-07-01-gds-l40s-campaign.md` — **both describe the retired
stage-1 fail-the-write design; superseded by
`docs/superpowers/specs/2026-07-29-p2pdma-v6-rework-design.md`**, which documents the
current v6 P2PDMA completion handling (§1.2 item 4). The still-deferred **self-heal**
design (in-driver CPU bounce on a P2P miss) remains future work, independent of the v6
rework, and lives on branch `p2pdma` as
`docs/…p2pdma-blk-sts-inval-and-self-heal-followup.md`.

---

## 12. First moves on the L40S box (suggested order)

1. **Sanity:** `mokutil --sb-state` (**Secure Boot must be off or MOK enrolled — see §3, do this first**); `uname -r`; `grep CONFIG_PCI_P2PDMA /boot/config-$(uname -r)`; `command -v bpftrace gdsio gdscheck`; `nvidia-smi`; `modinfo -F license nvidia` (want `GPL`/OpenRM); `cat /proc/driver/nvidia/version` (**≥ 595 on a ≥ 6.15 kernel — else apply §3.2 before anything GDS-native**); apply the §3.2 regkeys + verify `p2pmem/` per GPU; `cat /proc/cmdline` (note iommu settings for the evidence). If `CONFIG_PCI_P2PDMA` ≠ y or the NVIDIA module is proprietary, **stop and report** — native P2P won't work.
2. **Install:** kit `sudo ./install.sh` (featured **gdsM** + `/usr/sbin/msadm` + nvme-rdma override + udev rule + manifest — note the override's OK/WARNING line; `test -x /usr/sbin/msadm` should print, and P0 gates on `msadm_present`), or use the checkout's already-loaded modules. Confirm `/proc/msstat` shows `[raid1] [raid10]`. For the manual GDS-native probes (step 4) install the §4.6a test-only level-spoof (cuFile 1.15 is raid0-only) and remove it after — but the **campaign itself now owns and removes the p7 spoof**, so don't fight it during the main run.
3. **Verify gdsio's interface:** `gdsio -h` — cross-check the wrappers' flags (`-x` mode numbering, `-V` verify, `-I` read/write) before P1; fix only the two lib wrappers if they differ (§8 row). Pick the GPU index for `-d`: `nvidia-smi topo -m` — choose the GPU with the tightest path (PIX/PXB, not SYS) to the test NVMe.
4. **Partitions:** `sudo bin/perf-make-test-partitions /dev/nvmeXnY` (4K-LBA NVMe with trailing free space; make 4 across two drives for the raid10 fabric case, passed via `GDS_PART_LIST`). Confirm `/dev/disk/by-partlabel/*-meshstor-test-*`.
5. **Kernel check for the witness (§7):** if not a 6.17-class kernel, verify the pgmap/enum offsets and recalibrate on P1 before trusting P2/P3.
6. **Run the full campaign in one invocation** (`bin/gds-campaign --kit $PWD --results …` defaults to `p0..p7`), reading `verdict.tsv` after it: P0 → P1 → P2 (+ **`probe-cufile-recognition` on P2's mounted array**, §4.6) → P3(tcp then rdma) → P4a/b/c → **P6 the narrowness proof** (no longer needs its own invocation — the module-qualified probe made it run inline, even on root-on-md) → **P7 the P2P completion arm on GPU I/O** (the campaign manages its raid0 spoof) → P5's baseline swap. Exit 5 = INCOMPLETE (an unexpected P7 SKIP on a GPU box — treat as red). The manual strict-gdsio-on-baseline step (runbook §6) only once everything else is on disk.
7. **Collect evidence** (§10) **before** the window ends.

Work from the git checkout or the kit; keep the operator informed of every FAIL with its `.out` +
`.dmesg`. Fix tooling, escalate feature regressions, never fake a green.
