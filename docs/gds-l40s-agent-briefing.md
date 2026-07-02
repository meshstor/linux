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

The meshstor `ms_*` RAID driver (a renamed fork of Linux MD) has a 3-commit **P2PDMA feature**
that lets NVMe SSDs DMA **directly to/from L40S GPU memory** (GPUDirect Storage, "GDS native"),
bypassing CPU bounce buffers — across a topology of **local NVMe legs + remote NVMe-over-Fabrics
legs** (the MeshStor-CSI production shape). Your job: **prove GDS-native actually works through an
`ms` raid1/raid10 array, prove the per-member safety gating is correct, and reproduce the one
known integrity bug** — all with kernel-level evidence, not just cuFile's self-reporting.

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

### 1.2 The P2PDMA feature being validated (3 shipped commits on branch `p2pdma`)
PCI **P2PDMA** lets one PCIe device DMA to another's memory (NVMe ↔ GPU BAR) without bouncing
through host RAM. The block layer marks such bios and the queue advertises capability via the
`BLK_FEAT_PCI_P2PDMA` queue-limits feature (bit 12). It is deliberately **excluded** from
`BLK_FEAT_INHERIT_MASK`, so a stacking driver like md must set it **explicitly**.

The three commits (in `drivers/md`, already built into the loaded modules):

1. **Per-member advertise gate** — `raid1_can_advertise_p2pdma()` (in `raid1-10.c`, used by both
   raid1 and raid10): the array sets `BLK_FEAT_PCI_P2PDMA` **only when every non-faulty member's
   queue advertises it**. Upstream advertises unconditionally and relies on a 7.1-era
   `blk_stack_limits` member-AND that is **absent from every meshstor target kernel** — so md must
   do the AND itself. *Why it matters:* md is a pure router that never touches the pages; each
   member NVMe maps them, so a member that can't map GPU pages must never be handed P2P I/O.
2. **Hot-add clear** — `raid1_p2pdma_clear_on_add()`: adding a **non-P2P** member to an
   advertising array clears the advertisement **before** the new member becomes write-eligible
   (raid1 + raid10, normal-add and replacement slots). Guards against the same stale-advertise
   hazard on `mdadm --add`.
3. **P2P bio hygiene** — `md_bio_is_p2pdma()`: `md_submit_bio` **preserves `REQ_NOMERGE`** for P2P
   bios (merging P2P bios from different pgmaps at the member queue would map later segments with
   the wrong bus address → silent DMA corruption), and `raid1_write_request` **excludes P2P bios
   from write-behind** (write-behind CPU-touches pages, illegal for MMIO GPU pages).

### 1.3 The known, UNFIXED integrity bug (you will reproduce it, not fix it)
The advertise gate is **coarser than per-I/O reachability**. `blk_queue_pci_p2pdma(q)` means "this
queue can do P2P with *something*"; it does **not** mean a *specific* GPU can reach this member. The
real per-I/O check is `pci_p2pdma_state()` in the DMA-map path, which returns **`BLK_STS_INVAL`**
when *this* GPU's pages can't map to *this* member (crossing a root complex, ACS isolation,
multi-switch topology).

Today `raid1_should_handle_error()` treats `BLK_STS_INVAL` as **benign** → the failed leg is
marked uptodate → the **master bio reports success** even though the write never reached that
leg's media → **silent mirror divergence** (a later read from the stale leg returns garbage).
This is documented as a deferred follow-up (fail-the-write + self-heal). **Your P6 test reproduces
this bug deterministically as evidence — a PASS in P6 means "the bug is present as expected."**

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

---

## 3. Environment expectations (dev-box ground truth — verify on the L40S)

The tooling was authored and rehearsed on a box with these values. The L40S box should match the
load-bearing ones (kernel ≥ 6.11, CONFIG_PCI_P2PDMA=y, BTF, bpftrace); the rest may differ.

| Thing | Dev-box value | L40S must-have |
|---|---|---|
| Kernel | `6.17.0-35-generic` | **≥ 6.11** (for `BLK_FEAT_PCI_P2PDMA`); the shipped p2pdma feature is compiled in only then |
| `CONFIG_PCI_P2PDMA` | `=y` | **`=y`** — else native P2P is impossible regardless of md (authoritative gate; P0 checks it) |
| `CONFIG_DEBUG_INFO_BTF` | `=y` | **`=y`** — the bpftrace tools are BTF-only (no DWARF) |
| bpftrace | v0.20.2 | present |
| nvme-cli | 2.8 | present (flag caveat above) |
| ms modules | `ms_mod`,`raid1_ms`,`raid10_ms` loaded; `dkms: meshstor-ms/0.1.0.gds1` | install from kit (below) |
| `/proc/msstat` | `Personalities : [raid1] [raid10]` | same after modprobe |
| Secure Boot | off | **check `mokutil --sb-state` FIRST** — with SB enabled, unsigned DKMS modules are rejected at modprobe (`Key was rejected by service`). Enroll the DKMS MOK + reboot (`bin/mok-enroll` in the git checkout — **not shipped in the kit**; on a kit-only box use `mokutil --import /var/lib/dkms/mok.pub` or `…/shim/mok/…` per Ubuntu DKMS docs), or disable SB, **before** anything else — this alone can eat the window |
| GDS tools | **absent** on dev box | **`gdsio`+`gdscheck` REQUIRED on L40S** (CUDA 12.8+, NVIDIA **open** kernel module) — checked, not installed, by the kit |
| NVIDIA driver | n/a | **open driver ≥ 595 on ≥ 6.15 kernels** + two RM regkeys — see §3.2; 580.x cannot do kernel-native P2PDMA on 6.17 at all (UVM refcount bug) |
| mdadm | patched build at `/home/mykola/mdadm/mdadm` (kit: `bin/mdadm-ms`) | **required for ms arrays** — the stock/system mdadm **rejects `/dev/msN`** (unknown device names/major). Use the system mdadm only for in-tree `/dev/mdN` cleanup |

### 3.1 The kit (how to get the software onto the L40S box)
`build/gds-kit-0.1.0.tar.gz` (~1 MB) is self-contained: featured (`*.gds1`, member-AND) + baseline
(`*.gds0`, upstream unconditional-advertise) DKMS tarballs, the `bin/` tools, the `gds/`
selftests, the `inval-inject/` module source, the udev rule, `install.sh`, and the runbook. On the
box:
```
tar xzf gds-kit-0.1.0.tar.gz && cd gds-kit-0.1.0
sudo ./install.sh                      # dkms installs the FEATURED variant + modprobe + udev rule
sudo bin/perf-make-test-partitions /dev/nvmeXnY   # two (or 4) 25GiB GPT test partitions
sudo MDADM=$PWD/bin/mdadm-ms GDS_KIT_DIR=$PWD bin/gds-campaign --results /root/gds-results
```
If you are instead working **from the git checkout** at `/home/mykola/linux-meshstor` (patched
mdadm at `/home/mykola/mdadm/mdadm`, modules already installed), you can run the selftests and
`bin/gds-campaign` directly without the kit.

**Kit gap (found live):** `install.sh` installs the udev rule but NOT the `/usr/sbin/msadm`
binary that the rule's `IMPORT{program}` runs. Do it manually right after `install.sh`:
`sudo install -m0755 bin/mdadm-ms /usr/sbin/msadm`. Without it `/dev/msN` gets **no** `MD_*`
udev properties and cuFile fails with "Unsupported block device: /dev/ms0".

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
3. **cuFile userspace gates** — see §4.6a; the kernel being ready is necessary, not sufficient.

Topology note: the L40S box has no PIX/PXB GPU↔NVMe pairing (every GPU behind its own root
port, NVMes on one host bridge) — host-bridge (NODE) P2P **works** on Sapphire Rapids with
`iommu=pt` (P1 witnessed map_hits=512 on a raw partition).

---

## 4. The tooling — component contracts

All bash tools: exit **0 = pass, 1 = fail, 4 = skip, 2 = usage**. Tests source
`tools/testing/selftests/md/p2pdma/gds/lib.sh` (which sources the Layer-B
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

### 4.3 `dkms/inval-inject/` — the divergence injector (TEST-ONLY kprobe module)
Plain kbuild module (never a dkms package, never ship). A kprobe on `raid1_end_write_request`
rewrites a matching member's write completion **`BLK_STS_IOERR` → `BLK_STS_INVAL`**. Paired with
`dm-flakey error_writes` under one leg, it reproduces the exact P2P partial-reachability failure
shape without a GPU. Params: `disk=`, `partno=`, `remaining=` (arm), `injected=` (ro counter).
Refuses to matter while in-tree `raid1` is loaded (symbol ambiguity — the test guards this).

### 4.4 `bin/gds-campaign [--rehearsal] [--phases LIST] [--transport auto|rdma|rxe|tcp] [--results DIR] [--kit DIR]`
The single orchestrator. Runs phases in **strict priority order**, writes an evidence tree
`results/gds-campaign-<ts>/<phase>/` with per-phase `.out` + `.dmesg` deltas and a cumulative
`verdict.tsv` (`phase<TAB>test<TAB>PASS|FAIL|SKIP|INFO<TAB>detail`). Node **heartbeat** between
phases (stops on a wedge, exit 3). Campaign exits non-zero iff any row is FAIL (SKIPs tolerated).
`--rehearsal` = dev-box mode (skips GPU-only probes). Degradation: auto-detects transport
(real-rdma → rxe → tcp) and runs GPU-independent assertions even without gdsio.

### 4.5 The selftests (also runnable standalone as `sudo bash <path>`)
| File | Phase | What it asserts |
|---|---|---|
| `test_gds_raw_baseline.sh` | P1 | GDS-native works on a **raw** NVMe partition; calibrates the witness (CPU control reads map=0, native reads map>0). Gate. |
| `test_gds_raid1_local.sh` | P2 | **Headline**: GDS-native on an ms raid1 (both legs local), witness confirms P2P pages + map hits through the array, both mirror legs hold identical correct data. |
| `test_gds_raid1_fabric.sh` | P3 | CSI topology: local + loopback NVMe-oF leg (tcp default, `GDS_TRANSPORT=rdma`, `GDS_RAID10=1` for 4-member raid10). Records the Finding-E rdma answer; asserts array advertise == AND(members); witnessed GDS when advertising, clean compat when not. |
| `test_gate_tcp_leg_no_advertise.sh` | P4a | Member-AND: a tcp (non-P2P) leg makes the array NOT advertise. |
| `test_gate_hotadd_clears.sh` | P4b | `clear_on_add`: hot-adding a non-P2P (loop) member to an advertising array clears the advertisement; removal alone preserves it (raid1 + raid10). |
| `test_divergence_inval.sh` | P6 | **Reproduces the bug**: injected INVAL is swallowed → write reports success, `[UU]` preserved, leg silently stale; IOERR control correctly faults the leg. PASS = bug present as expected. |
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
   cuFile-native GDS on raid1/raid10 for stock md too; it is NOT an ms issue. Consequence:
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

---

## 5. Phase plan and the EXPECTED RESULTS MATRIX

Run priority order; highest-value/lowest-risk first. P5/P6 last (they swap packages / inject faults).

| Phase | Command (from repo root, as root) | Expected on a healthy P2P-capable L40S | Expected if GPU/gdsio absent |
|---|---|---|---|
| **P0** | `bin/gds-campaign --phases p0` | `pci_p2pdma_config PASS`, `bpftrace PASS`, `modules PASS`, transport INFO, partitions INFO; GPU/OpenRM/gdscheck rows | same minus GPU rows |
| **P1** | `sudo bash …/test_gds_raw_baseline.sh` | PASS: control map=0, native map>0, read-verify ok | **SKIP rc=4** `gdsio not found` |
| **P2** | `sudo bash …/test_gds_raid1_local.sh` | PASS: advertise, witness p2p_bios>0 & map_hits>0, both legs identical | **SKIP rc=4** (before touching devices) |
| **P3 tcp** | `sudo GDS_TRANSPORT=tcp bash …/test_gds_raid1_fabric.sh` | INFO `local=1 remote=0`; `advertise_consistency PASS array=0`; advertise-only PASS | same (advertise logic is GPU-independent) → PASS |
| **P3 rdma** | `sudo GDS_TRANSPORT=rdma bash …/test_gds_raid1_fabric.sh` | INFO records whether rdma leg advertises (**new data**); if array advertises + gdsio: witnessed native PASS + leg integrity | SKIP if no RDMA NIC / no gdsio |
| **P4a** | `sudo bash …/test_gate_tcp_leg_no_advertise.sh` | PASS: local adv, tcp ns not, array not | PASS (GPU-independent) |
| **P4b** | `sudo bash …/test_gate_hotadd_clears.sh` | PASS: advertise → persist on remove → cleared on non-P2P add (raid1+raid10) | PASS (GPU-independent) |
| **P5** | `bin/gds-campaign --phases p5 --kit <dir>` | baseline swap: tcp-leg array **falsely** advertises (baseline has no member-AND) = expected finding; restore featured PASS | needs `--kit`; else SKIP |
| **P6** | `sudo bash …/test_divergence_inval.sh` | PASS: `BLK_STS_INVAL swallowed … injected=N` (N≥1), `[UU]` preserved, leg stale | PASS (loop substrate ok, GPU-independent) |

**Dev-box confirmed live (banked evidence):** P4a, P4b, P6 all PASS; P1/P2/P3-GDS SKIP (no gdsio);
P3 advertise-consistency PASS at raid1 + raid10 (tcp: `local=1 remote=0`, array=0). P6 reproduced
with `injected=64`. So on the L40S the **new** results are P1/P2/P3-native (GPU), the P3-rdma
Finding-E answer, and the cuFile-recognition verdict (§4.6).

**L40S confirmed live (2026-07-02, gpu-cluster-manassas, nvidia 595.71.05):** P0 PASS; P1 PASS
(control map=0 / native map_hits=512); P2 PASS **kernel-witnessed under the §4.6a level-spoof**
(p2p_bios=520, map_hits=779, legs identical) — without the spoof P2 FAILs at cuFile registration
(raid0-only policy), which is the expected shape on cuFile 1.15, not a regression; recognition
probe rc=0. P3 tcp raid1+raid10 PASS; P3 rdma answered on rxe (leg does not advertise); P4a/P4b
PASS; P5 PASS incl. the manual strict-gdsio step (benign userspace refusal, §4.6a gate 3);
P6 permanent SKIP on that box (root fs on in-tree md RAID1 → `raid1.ko` unremovable — the guard
is correct; don't fight it, bank the dev-box repro).

**Pacing for a few-hours window** (rough budgets): P0 ~10 min, P1 ~15, P2 ~20, P3 ~30, P4 ~30,
P5 ~20, P6 remainder. Add `probe-cufile-recognition` right after P2 (~10 min) while its array is
still mounted. Evidence flushes per-phase, so a truncated window still yields conclusions.

**Risk ordering is deliberate:** P5 and P6 are last because they are the phases most likely to
wedge or crash the node (false-advertise routing, fault injection) — by then all shipped-commit
evidence is on disk. P5 also has an **optional manual step** (runbook §6): with the baseline
package installed and a tcp-leg array mounted, drive a **strict** gdsio write under the witness and
save dmesg — this is the single crash-riskiest action of the window; do it only after p0–p4
evidence is safely on disk, and expect anything from BLK_STS_INVAL errors to works-but-slow (P2P
pages have kernel vaddrs, so nvme-tcp's CPU copy may function with degraded performance). Whatever
happens **is** the finding — record it verbatim. After any P5 activity, verify the box is back on
the featured package: `dkms status` must show `*.gds1`, and a fresh tcp-leg array must NOT
advertise (member-AND is featured-only). If the featured re-install fails, the campaign aborts
loudly with exit 3 and the box is left on baseline — reinstall featured before trusting anything
that runs afterwards.

---

## 6. PRE-DIAGNOSED HAZARDS (read before you debug anything — these are expected, not bugs)

These were hit and root-caused during development. **Do not "fix" the campaign in response to
these — handle them operationally as described.**

1. **P6 SKIPs after P4 in an unattended full run.** P4 creates arrays; writing md superblocks makes
   **udev's `64-md-raid-assembly.rules` autoload the in-tree `raid1`/`raid10` modules** and
   incrementally assemble. In-tree `raid1` then shares the `raid1_end_write_request` symbol with
   `raid1_ms`, so the P6 kprobe binding is ambiguous and the test **guards by SKIPping** when
   `/sys/module/raid1` exists.
   **→ Operational fix:** run **P6 as its own invocation**: stop any in-tree md array
   (`cat /proc/mdstat`; `mdadm --stop` with the **system** mdadm), `sudo modprobe -r raid1 raid10`,
   then run `test_divergence_inval.sh` (or `--phases p6`). Confirm with
   `grep raid1_end_write_request /proc/kallsyms` showing only `[raid1_ms]`.

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

8. **P6 permanently SKIPs on boxes whose root fs lives on in-tree md** (common on cloud L40S
   nodes — the Manassas box boots from an md RAID1 pair). `raid1.ko` can never be unloaded, so
   the kprobe-ambiguity guard always fires. **→ Bank the dev-box reproduction; do not try to
   defeat the guard.**

---

## 7. PORTABILITY: what may silently misbehave if the L40S kernel ≠ 6.17-class

The bpftrace tools read kernel structs by BTF. If the L40S box runs a **materially different
kernel**, verify before trusting counts:
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
| P0 `pci_p2pdma_config FAIL` | kernel built without `CONFIG_PCI_P2PDMA=y` | **Stop** — native P2P is impossible on this kernel. Report; use a kernel with it =y. Not fixable in tooling. |
| gdsio errors on flags / unexpected `-x`/`-V` behavior | the wrappers' gdsio flags (`-d 0 -w 4 -s 256M -i 1M -x {0,1} -I {0,1} -V`) were written from docs, **never run against a real gdsio** | `gdsio -h` FIRST; if mode numbering or verify semantics differ, fix ONLY the two wrappers `gds_gdsio_write`/`gds_gdsio_readverify` in `gds/lib.sh` (they isolate this exact risk), re-run unit gate + P1. |
| cuFile refuses the file on an ms array (`Unsupported block device` / `RAID level not supported` / `RAID member not supported`) despite witness proving raw-partition native | one of cuFile's **three userspace gates** (§4.6a): missing `MD_*` props (msadm/rule), the **raid0-only level policy**, or a non-PCIe member transport | Walk the §4.6a ladder in order: `udevadm info --query=property /dev/msN | grep MD_` (empty → install `/usr/sbin/msadm` + trigger); `RAID level not supported` → expected on raid1/raid10, use the test-only level-spoof for kernel-path evidence + escalate as product finding; `unknown NVMe transport` → cuFile's own member AND, working as designed. |
| `ms-queue-features` always rc=4 | bpftrace can't attach; no BTF; probe symbol missing | `bpftrace -l 'kprobe:submit_bio*'`; check `CONFIG_DEBUG_INFO_BTF=y`; check `/sys/kernel/tracing/available_filter_functions`. Fix probe name if the submit path differs on this kernel. |
| P1 native `map_hits=0` (control also 0) | **First suspect: the NVIDIA driver gates (§3.2)** — regkeys missing (cufile errornum **801**) or 580.x-vs-≥6.15 UVM refcount bug (errornum **1** + driver-open 5001); then ACS/IOMMU; then topology | Check `/sys/bus/pci/devices/<gpu>/p2pmem/` exists; grep cufile.log for `errornum: 801` (→ regkeys) vs `errornum: 1` (→ driver < 595); `gdscheck -p`; `nvidia-smi topo -m` (all-NODE is fine on SPR+`iommu=pt` — confirmed). If the box genuinely can't do native GDS, P1 is a legitimate FAIL — record it, fall back to advertise-only mode for P2–P4. |
| P2 witness `p2p_bios=0` but cuFile says native | cuFile bounced silently; or witness attach failed | Check witness `-o` dump: if `host_bios>0` the probe fired and cuFile really bounced (real FAIL — investigate cuFile/topology). If witness rc=4, it's a SKIP not FAIL. |
| P2/P3 witness `p2p_bios>0` on a **CPU** run (false positive) | pgmap union misread on wrong kernel (§7) | Recalibrate on P1 (control must be 0). If control ≠ 0, fix the folio/enum in `gds-p2p-witness` and re-verify. |
| P2 `advertise FAIL` intermittently | probe flake (rc=4 folded) — should already SKIP | Confirm you're on the post-fix tests (three-way rc). Re-run; a genuine `advertise FAIL` on an all-NVMe array = real member-AND regression (investigate the feature, not the test). |
| P3 array advertises with a **tcp** leg | member-AND regression **or** you're on the **baseline** package | `ms-queue-features` each member; `dkms status` (must be `*.gds1` featured, not `*.gds0`). If featured and it still advertises → real bug in `raid1_can_advertise_p2pdma`; capture and report. |
| P4b advertisement not cleared after non-P2P `--add` | `clear_on_add` regression, or add landed as spare and clear fires on activation | `mdadm --detail /dev/ms0`; re-read advertise after the member is truly active. If still advertising with an active non-P2P member → real bug. |
| P6 SKIPs "in-tree raid1 loaded" | udev autoloaded raid1 (hazard #1) | `modprobe -r raid1 raid10` (stop in-tree arrays first), re-run. |
| P6 FAIL "injector never fired" | kprobe didn't bind; symbol ambiguity; module build failed | `grep raid1_end_write_request /proc/kallsyms` (only `[raid1_ms]`?); `dmesg` for insmod errors; rebuild `make -C dkms/inval-inject`. |
| P6 FAIL "write returned rc≠0" or a leg faulted | **the bug is fixed** (fail-the-write shipped) OR rig broke | If `raid1_should_handle_error` now handles INVAL, the `[FLIP]` markers in the test must be inverted — this is a *feature landing*, not a test bug; confirm with the operator before flipping. Otherwise check dm-flakey table syntax + `safe_mode_delay`. |
| Node wedged, kthreads in D state | a real deadlock; or you ran with `MD_SUBSYS=md` | **Never set `MD_SUBSYS=md`** — the raid10 recovery-freeze test wedges in-tree kthreads (reboot to clear). Copy `results/` off, reboot, resume with `--phases`. |
| Array won't create ("device busy"/superblock) | stale superblock or udev grabbed the device | `mdadm --stop`; `mdadm --zero-superblock <dev>` (system mdadm for /dev/mdN, patched for members); `wipefs -a` as last resort on a **test** partition only. |

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
- Enable `allow_compat_mode: true` to get a "native" pass.
- Push, force-push, or rewrite history without the operator saying so.

**ESCALATE to the operator (report clearly, don't guess) when:**
- A shipped-feature assertion genuinely FAILs (member-AND, clear_on_add, silent-divergence
  behavior changed) — this is a real finding, the whole point of the campaign.
- P1 can't do native GDS at all (topology/ACS/driver) — needs a human hardware call.
- P6's bug appears **fixed** (INVAL now handled) — that's a feature landing; the `[FLIP]` markers
  need inverting, confirm intent first.
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
tools/testing/selftests/md/p2pdma/gds/            the 6 phase tests + lib.sh + unit test
tools/testing/selftests/md/p2pdma/lib.sh          Layer-B helpers (sourced by gds/lib.sh)
tools/testing/selftests/md/p2pdma/test_*.sh       Layer-B non-P2P regression suite (run under P4)
dkms/inval-inject/                                divergence injector (make -C to build)
dkms/udev/63-ms-raid-arrays.rules                 cuFile RAID-classification udev rule
docs/gds-l40s-runbook.md                          concise window runbook (procedure + abort)
build/gds-kit-0.1.0.tar.gz                        the scp-able kit
```
Design spec + implementation plan (deeper rationale, gitignored local archive):
`docs/superpowers/specs/2026-07-01-gds-l40s-p2pdma-campaign-design.md` and
`docs/superpowers/plans/2026-07-01-gds-l40s-campaign.md`. The deferred integrity-bug design lives
on branch `p2pdma` as `docs/…p2pdma-blk-sts-inval-and-self-heal-followup.md`.

---

## 12. First moves on the L40S box (suggested order)

1. **Sanity:** `mokutil --sb-state` (**Secure Boot must be off or MOK enrolled — see §3, do this first**); `uname -r`; `grep CONFIG_PCI_P2PDMA /boot/config-$(uname -r)`; `command -v bpftrace gdsio gdscheck`; `nvidia-smi`; `modinfo -F license nvidia` (want `GPL`/OpenRM); `cat /proc/driver/nvidia/version` (**≥ 595 on a ≥ 6.15 kernel — else apply §3.2 before anything GDS-native**); apply the §3.2 regkeys + verify `p2pmem/` per GPU; `cat /proc/cmdline` (note iommu settings for the evidence). If `CONFIG_PCI_P2PDMA` ≠ y or the NVIDIA module is proprietary, **stop and report** — native P2P won't work.
2. **Install:** kit `sudo ./install.sh`, then `sudo install -m0755 bin/mdadm-ms /usr/sbin/msadm` (§3.1 kit gap — required for cuFile classification), or use the checkout's already-loaded modules. Confirm `/proc/msstat` shows `[raid1] [raid10]`. For the GDS-native phases install the §4.6a test-only level-spoof (cuFile 1.15 is raid0-only) and remove it after.
3. **Verify gdsio's interface:** `gdsio -h` — cross-check the wrappers' flags (`-x` mode numbering, `-V` verify, `-I` read/write) before P1; fix only the two lib wrappers if they differ (§8 row). Pick the GPU index for `-d`: `nvidia-smi topo -m` — choose the GPU with the tightest path (PIX/PXB, not SYS) to the test NVMe.
4. **Partitions:** `sudo bin/perf-make-test-partitions /dev/nvmeXnY` (4K-LBA NVMe with trailing free space; make 4 across two drives for the raid10 fabric case, passed via `GDS_PART_LIST`). Confirm `/dev/disk/by-partlabel/*-meshstor-test-*`.
5. **Kernel check for the witness (§7):** if not a 6.17-class kernel, verify the pgmap/enum offsets and recalibrate on P1 before trusting P2/P3.
6. **Run in priority order**, reading `verdict.tsv` after each: P0 → P1 → P2 (+ **`probe-cufile-recognition` on P2's mounted array**, §4.6) → P3(tcp then rdma) → P4a → P4b → then **P6 in its own invocation** (unload in-tree raid1 first) → P5 last (needs `--kit`; verify featured restored after; the manual strict-gdsio-on-baseline step only once everything else is on disk).
7. **Collect evidence** (§10) **before** the window ends.

Work from the git checkout or the kit; keep the operator informed of every FAIL with its `.out` +
`.dmesg`. Fix tooling, escalate feature regressions, never fake a green.
