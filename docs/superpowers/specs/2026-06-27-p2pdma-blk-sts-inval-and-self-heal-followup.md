# P2PDMA raid1/raid10 — `BLK_STS_INVAL` error path + automatic self-heal (standalone follow-up spec)

- Date: 2026-06-27
- Status: deferred follow-up — design ready, needs implementation + **hardware** validation.

---

## 0. Where this sits (current state — read first)

This is a **meshstor `linux` fork** packaged as out-of-tree DKMS modules (`ms_mod`,
`raid1_ms`, `raid10_ms`) renamed from `drivers/md/` via a `md_*`→`ms_*` pass. Branch model:

- **`origin/master`** — torvalds `master` (filtered to `drivers/`), currently 7.2-era.
- **Feature branches** (e.g. `p2pdma`, `llbitmap-fixes`) — rebased on `origin/master`,
  carry **pure `drivers/md` source** (no `#ifdef`/compat) + runtime selftests under
  `tools/testing/selftests/md/<feature>/`.
- **`meshstor-harness`** — the packaging/compat side: `dkms/` (rename rules,
  `compat/compat.h`, structural `patches/*.patch`, `Makefile.in` feature-flag probes),
  `bin/`, `docs/`, and the dkms-pipeline selftests under `tools/testing/selftests/dkms/`.
- `bin/rebuild-main <feature-branch>` composes `master` + feature branches; `bin/build-tarball`
  copies `drivers/md` from that tree, applies `dkms/patches/*`, runs the rename, compiles.

**What the base P2PDMA work already shipped (do not redo):**
- Branch **`p2pdma`** (on `origin/master`), commit `510af1f0` — the md feature, pure
  source in `drivers/md`:
  - `raid1_can_advertise_p2pdma(struct mddev *mddev)` in `raid1-10.c` — advertise
    `BLK_FEAT_PCI_P2PDMA` only when **every non-faulty member** has
    `blk_queue_pci_p2pdma(bdev_get_queue(rdev->bdev))`. Called from `raid1_set_limits`
    (`raid1.c`) and `raid10_set_queue_limits` (`raid10.c`), after `mddev_stack_rdev_limits`,
    replacing upstream's unconditional `lim.features |= BLK_FEAT_PCI_P2PDMA;`.
  - `md_bio_is_p2pdma(struct bio *bio)` in `md.h` — `bio_has_data(bio) && bio->bi_vcnt &&
    is_pci_p2pdma_page(bio->bi_io_vec->bv_page)` (reads `bi_io_vec[0]` directly; clone-safe vs
    the `bio_first_bvec_all` `BIO_CLONED` WARN).
  - `md_submit_bio()` in `md.c` preserves `REQ_NOMERGE` for P2P bios
    (`if (!md_bio_is_p2pdma(bio)) bio->bi_opf &= ~REQ_NOMERGE;`).
  - `raid1_write_request()` in `raid1.c` skips write-behind for P2P bios
    (`… && test_bit(WriteMostly,…) && !md_bio_is_p2pdma(bio)`).
- Branch **`meshstor-harness`** (compat side), commits `cb85cddc` (P2P dkms support) + `0391c6cd`
  (`bh_submit` shim) + `06a4a263` (cuFile tooling):
  - `dkms/patches/0008-p2pdma-feature-flag-gating.patch` wraps every feature site above in
    `#ifdef HAVE_BLK_FEAT_PCI_P2PDMA` so it compiles out on pre-6.11 kernels (and
    `md_bio_is_p2pdma` folds to `return false`).
  - `dkms/Makefile.in` probes `HAVE_BLK_FEAT_PCI_P2PDMA` and `HAVE_BH_SUBMIT`; `compat.h`
    has the `BLK_FEAT_PCI_P2PDMA → 0` fallback and the `bh_submit`/`bio_endio_bh` shim.
  - dkms selftests `test_0005` (flag detection) and `test_0008` (assembly pipeline).
- **Base error-path behaviour:** `raid1_should_handle_error()` (in `raid1-10.c`, shared by
  raid1+raid10) is **left upstream** — it returns false for `BLK_STS_INVAL`, i.e. the base
  **swallows** it. That is what this follow-up changes.

**This follow-up adds:** the md SOURCE for the error path + self-heal → goes on
**`p2pdma`** (`drivers/md`). Any new kernel-API gating → a dkms compat patch on
**`meshstor-harness`**. It needs runtime hardware validation (§8) that CI cannot provide.

> **Line numbers below track `origin/master` tip and drift** — locate by symbol/function,
> not by line.

---

## 1. Background: upstream P2PDMA in MD

PCI **P2PDMA** lets a PCIe device (e.g. an NVMe SSD) DMA directly to/from another device's
memory (e.g. GPU memory for GPUDirect Storage) without bouncing through host RAM. The block
layer marks such bios and the queue advertises the capability via the
`BLK_FEAT_PCI_P2PDMA` queue-limits feature (bit 12; **deliberately absent** from
`BLK_FEAT_INHERIT_MASK`, so a stacking driver like md must set it explicitly).

Upstream added P2PDMA to MD as a **three-patch series** (NVIDIA authors; reviewed by
Hellwig/Sagi/Xiao Ni; merged ~7.1, dated 2026-05-26):

| commit | role |
|---|---|
| `fb0eeeed91f3` | nvme-multipath: enable P2PDMA on the mpath device |
| `7882834048f1` | **block core**: `blk_stack_limits()` *clears* `BLK_FEAT_PCI_P2PDMA` for any non-supporting member (next to the existing `BLK_FEAT_NOWAIT`/`BLK_FEAT_POLL` clears) |
| `02666132403a` | md: advertise `BLK_FEAT_PCI_P2PDMA` **unconditionally** in raid0/1/10 `*_set_limits` |

Upstream's model: the personality advertises unconditionally; the **block core** does the
per-member AND. Parity RAID (4/5/6) is excluded because parity needs CPU access to data
pages, incompatible with P2P (MMIO) pages.

**Why meshstor does the member-AND in md instead:** the block-core clear `7882834048f1` is
2026-05-26 (7.1) and is **absent from every meshstor target kernel** (RHEL9 5.14, RHEL10
6.12, Ubuntu-HWE 6.14, Ubuntu 6.17). So on those kernels nothing clears a falsely-advertised
flag — md must AND it across members itself. That is the `raid1_can_advertise_p2pdma()` helper
already on `p2pdma` (§0).

---

## 2. The problem this follow-up solves

**The advertise gate is coarser than per-I/O reachability.** `blk_queue_pci_p2pdma(q)` is
`q->limits.features & BLK_FEAT_PCI_P2PDMA`, set by the nvme driver based on
`dma_pci_p2pdma_supported(dev->dev)` — a **device-general** "this queue can do P2P with
*something*" capability. It does **not** mean a *specific* GPU can reach this device. The real,
per-I/O check is `pci_p2pdma_state()` in the DMA-map path: in `block/blk-mq-dma.c` its
`default:` (i.e. `PCI_P2PDMA_MAP_NOT_SUPPORTED`) case sets `iter->status = BLK_STS_INVAL`
when *this* GPU's pages cannot be mapped to *this* member (no P2P path — e.g. across a root
complex, ACS isolation, multi-switch / multi-GPU topology).

So **an array that legitimately advertises P2P (all members are P2P-capable) can still get
`BLK_STS_INVAL` on a per-leg write** when the writing GPU can't reach that leg.

**What md does with it today (base = upstream):** `raid1_should_handle_error()` returns
`false` for `BLK_STS_INVAL` (it's treated as benign "invalid I/O" — LBS/atomic bounds), so in
`raid1_end_write_request()` `ignore_error` is true → the failed leg takes the success branch
and sets `R1BIO_Uptodate` → the master bio **reports success**. But the write never reached
that leg's media → **silent mirror divergence**: that leg is stale, and a later read served
from it returns garbage. This is the integrity gap this follow-up closes.

> **Scope / when it actually bites.** The divergence requires an **asymmetric** topology: the
> writing GPU can reach *some* legs but not others, while *every* leg is still device-general
> P2P-capable (so the array advertises and `md_bio_is_p2pdma` marks the bio). In the common GDS
> layout — GPU and all NVMe under one PCIe switch — every leg is equally reachable, no leg
> returns `BLK_STS_INVAL`, and the gap never opens. So this is a real but topology-dependent
> integrity bug, and any hardware validation (§7) must deliberately build the asymmetric path
> (e.g. one leg across a root complex / behind ACS isolation) to reproduce it at all.

---

## 3. The decision: option (c), fail-the-write + self-heal

Three behaviours for a P2P bio completing `BLK_STS_INVAL`:

| | divergence? | faults a healthy leg? | notes |
|---|---|---|---|
| **(a)** handle-as-error (fault/bad-block the leg) | no | **yes** | The coarse flag can't predict per-GPU reachability, so this degrades a *healthy* leg for a transient GPU↔device path issue. Contradicts upstream's stance that `BLK_STS_INVAL` is "a user error, not a device failure." |
| **(b)** swallow (upstream / current base) | **yes (silent)** | no | The integrity gap in §2. |
| **(c)** fail the *whole write* to the submitter; fault nothing; self-heal the range | no | no | **Chosen.** Loud error (submitter — e.g. cuFile — falls back to a non-P2P/bounce path), no healthy-device fault, and the divergent range is auto-remirrored. |

Why (c) is deferred (not shipped in the base): it is **untestable in CI** (no P2P-capable
hardware — see Finding E) and its dead-failure mode is silent divergence; two prior naive
implementations shipped *runtime-dead* (Finding K). Doing it correctly requires runtime
hardware validation and a daemon-context redesign for self-heal (Finding O) — so it is its own
hardware-validated change, designed here.

---

## 4. Findings catalogue (the forensics)

These are the load-bearing facts; the design in §5 follows from them.

> **Verification provenance.** E/J/K(md side)/L/M/N/O/P/Q/R/S were re-checked **directly**
> against the `drivers/md` source on this branch (the feature tree carries only `drivers/`).
> The three claims that reach outside `drivers/md` — `__bio_clone` leaving `bi_vcnt==0`
> (Finding K), `blk-mq-dma.c` mapping `PCI_P2PDMA_MAP_NOT_SUPPORTED → BLK_STS_INVAL` (§2), and
> the nvme-tcp ctrl-op absence (Finding E) — could **not** be read from `block/`/`nvme/host`
> here. They rest on: the per-leg bio being a provable `bio_alloc_clone` plus the base `md.h`
> comment's own `BIO_CLONED` note (K); the documented `PCI_P2PDMA_MAP_NOT_SUPPORTED` contract
> "DMA Mapping routines should return an error" (§2); and remain **unverified** for E. Confirm
> them against a full `origin/master` checkout before relying on E for the test plan.

- **E (testability).** `nvme-tcp` has **no** `supports_pci_p2pdma` ctrl op — only `nvme-pci`
  (`drivers/nvme/host/pci.c`) and `nvme-rdma` (`drivers/nvme/host/rdma.c`) define it, and
  `drivers/nvme/host/core.c:4205` gates the advertise on that op. So an `nvme-tcp` leg **never**
  sets `BLK_FEAT_PCI_P2PDMA`; an array containing one can't do P2P at all. Consequence: a
  loopback `nvme-tcp` test rig **cannot** exercise the kernel-native P2P path — validation needs
  a P2P-capable leg (`nvme-pci`/`nvme-rdma`).
- **J (the core hazard).** Because the advertise flag is device-general (§2), `BLK_STS_INVAL`
  on an advertised array is a real per-GPU-reachability failure — which is exactly why
  option (a) over-faults healthy legs and why option (c) must fail the *write* (not the device).
- **K (dead end-io detector — the trap to avoid).** The per-leg write bio that reaches
  `*_end_write_request` is a `bio_alloc_clone()` (`raid1.c`, `raid10.c`): `bio_alloc_clone`
  allocates with `nr_vecs=0` and `__bio_clone` (`block/bio.c`) copies `bi_iter` but **never
  sets `bi_vcnt`** — it only repoints `bi_io_vec` at the source's bvecs. So a clone has
  **`bi_vcnt == 0`**, and any `&& bio->bi_vcnt`-guarded detector on the end_io bio is **always
  false**. Two prior implementations (`md`'s old `0010`-style patch, and earlier iterations of this very design)
  detected P2P-ness on the clone and so were **runtime-dead no-ops** — they compiled and passed
  source-presence tests while never firing. **Detect at submit time on the original bio
  instead** (§5.1).
- **L (no automatic self-heal without help).** The write-intent bitmap dirty bit is cleared
  **unconditionally** on write completion: `md_end_clone_io()` (`drivers/md/md.c:9396`) calls
  `md_bitmap_end()` → `bitmap_ops->end_write` whenever `bio_data_dir(orig_bio)==WRITE`, **not**
  gated on `bi_status`. So under option (c) alone the diverged region is accounted **clean** —
  no bad-block/rebuild, no fault/rebuild, no crash-resync. Only a manual
  `echo repair > …/sync_action` would converge it. → self-heal must be added (§5.3).
- **M (refcount).** The new P2P-error completion arm must **fall through** to
  `r1_bio_write_done()` (`raid1.c:576`), which owns `atomic_dec_and_test(&r1_bio->remaining)`.
  An early `return` leaks/hangs the r1_bio.
- **N (mixed-error precedence).** `r1_bio_write_done()` checks `R1BIO_WriteError` **first**
  (`raid1.c:458`) → `reschedule_retry`. If one leg takes a real IO error while the P2P leg sets
  the P2P-error flag, the real-error leg keeps its normal fault/bad-block handling and the
  P2P-error master override still applies when completion reaches `call_bio_endio`. Define this
  precedence; ensure `narrow_write_error()` is **not** run on the P2P leg (re-submitting the
  unreachable P2P pages just re-fails). **Mechanism:** the only way to exclude the P2P leg is to
  set `r1_bio->bios[mirror] = NULL` (`to_put = bio`) in the new arm, exactly as the success
  branch does (`raid1.c:520-521`); `handle_write_finished()` runs `narrow_write_error` for every
  `bios[m] != NULL` (`raid1.c:2621-2627`). Nulling it is therefore mandatory — and it is what
  couples N to Finding R (it also drops the leg out of the `fail` set, so the daemon arm, not
  `handle_write_finished`, must own `close_write`).
- **O (`dirty_bits` is process-context — why self-heal can't be inline).**
  `bitmap_ops->dirty_bits` has exactly **one** caller in-tree: `bitmap_store()`
  (`drivers/md/md.c:4907`), the `bitmap_set_bits` sysfs handler — it runs in process context
  under `mddev_lock` (a mutex) and is followed by `unplug` to flush. `bitmap_dirty_bits`
  (`md-bitmap.c`) → `md_bitmap_set_memory_bits` → `md_bitmap_checkpage` does
  `kzalloc(PAGE_SIZE, GFP_NOIO)` (`md-bitmap.c:287`, can **sleep**) and mutates
  `mddev->resync_offset` unlocked. A `bi_end_io` completion callback (atomic/softirq) **cannot**
  do any of that. → defer self-heal to the daemon (§5.3).
- **P (override placement).** `call_bio_endio()` (`raid1.c:321`) sets
  `bio->bi_status = BLK_STS_IOERR` when `!R1BIO_Uptodate`. The P2P-error override must be placed
  **after** that line (or as `else if`); placing it before lets `BLK_STS_IOERR` clobber the
  intended `BLK_STS_INVAL` in the **all-legs-unreachable** case (isolated GPU / degraded array).
- **Q (raid10 naming).** raid10 has **no** `call_bio_endio` — its master completion is
  `raid_end_bio_io()` (`raid10.c:320`), with the `IOERR` line at `raid10.c:326` inside a
  `!test_and_set_bit(R10BIO_Returned,…)` guard. Place the raid10 override there.
- **R (write-counter balance — the P2P-error arm must `close_write`).** Every raid1/raid10 write
  calls `md_write_start()` once (`raid1.c:1752`, `raid10.c:1896`), balanced by
  `close_write()`→`md_write_end()` (`raid1.c:450,461`; raid10 `raid10.c:432-436`).
  `handle_write_finished()` only calls `close_write` when `R1BIO_WriteError` is set
  (`raid1.c:2644-2645`; raid10 `raid10.c:2975,3010`). A **pure** `R1BIO_P2PError` r1_bio — which
  §5.2 deliberately does **not** mark `R1BIO_WriteError` — reaches neither the WriteError
  `close_write` nor (because Finding N nulls its leg) the success-branch `close_write`. Result:
  `md_write_end` is skipped, `writes_pending` leaks, and the array can no longer quiesce/suspend
  (`mddev_suspend`, reshape, and `MD_RECOVERY_*` all wait on it). The P2P-error completion arm
  must call `close_write()` **explicitly**. This is unaddressed in the original §5.3 and is the
  single most likely silent regression of a naive implementation.
- **S (detect *before* `md_account_bio`, or the detector is dead again — Finding K reincarnated).**
  `md_account_bio()` (`raid1.c:1650`, `raid10.c:1230/1506/1761`) **replaces** the make-request
  `bio` with its own `bio_alloc_clone` (`md.c:9425`), whose `bi_vcnt==0` like every clone. So
  `md_bio_is_p2pdma()` evaluated **after** `md_account_bio` returns false and `R1BIO_P2P` would
  never be set — runtime-dead exactly as Finding K. Set `R1BIO_P2P` at the existing write-behind
  detection site (`raid1.c:1581`), which runs **before** `md_account_bio`, where the original
  bio still has `bi_vcnt>0`. §5.1's "same place write-behind uses `md_bio_is_p2pdma`" is correct
  *only* because that site precedes the clone; make the ordering constraint explicit.

---

## 5. Design

All of §5 is **md source → branch `p2pdma`** (`drivers/md`), pure (no `#ifdef`). The
existing `dkms/patches/0008-p2pdma-feature-flag-gating.patch` on `meshstor-harness` must be extended to
also `#ifdef HAVE_BLK_FEAT_PCI_P2PDMA`-gate the new sites (so they still compile out on
pre-6.11), and the `dkms` selftests updated.

### 5.1 Detection — submit-time flag (corrects Finding K)
Do **not** inspect the end_io clone. At **submit** time, where the original bio still has
`bi_vcnt>0` (the same place §0's REQ_NOMERGE/write-behind already use `md_bio_is_p2pdma`),
record P2P-ness into a **new r1_bio/r10_bio state bit** `R1BIO_P2P`/`R10BIO_P2P`:
- in `raid1_write_request()` / raid10's make-request: `if (md_bio_is_p2pdma(bio))
  set_bit(R1BIO_P2P, &r1_bio->state);`
- **Placement is load-bearing (Finding S):** this must run **before** `md_account_bio()`
  (`raid1.c:1650`), which swaps `bio` for a `bi_vcnt==0` clone. Put it at/near the write-behind
  site (`raid1.c:1581`), *not* after `md_account_bio`, or `md_bio_is_p2pdma` sees the clone and
  the bit never sets — the same dead-detector trap this section exists to avoid.
- state bits are free (`enum r1bio_state` uses ~8 of an `unsigned long`); `r1_bio` is
  `kzalloc`'d and `init_r1bio` sets `state=0` (`raid1.c:1319`), so the bit defaults clear — no
  collision.

### 5.2 Fail-the-write
- *Interception* in `raid1_end_write_request()` / `raid10_end_write_request()`: on
  `bio->bi_status == BLK_STS_INVAL && test_bit(R1BIO_P2P, &r1_bio->state)`, take a **new arm**
  of the per-leg if/else — set `R1BIO_P2PError`/`R10BIO_P2PError`, do **not** set
  `…Uptodate`, do **not** enter the `WriteErrorSeen`/`R1BIO_WriteError` fault path; **also set
  `r1_bio->bios[mirror] = NULL` and `to_put = bio`** (mirroring the success branch,
  `raid1.c:520-521`) so the unreachable leg is excluded from `narrow_write_error` (Findings N,
  R) — and **fall through to `r1_bio_write_done`** (Finding M; no early return).
- *Master completion:* in `call_bio_endio` (raid1.c:321) / `raid_end_bio_io` (raid10.c:320,
  Finding Q), **after** the `if(!…Uptodate) bi_status = BLK_STS_IOERR;` line (Finding P), add
  `if (test_bit(…_P2PError, &r1_bio->state)) bio->bi_status = BLK_STS_INVAL;`. (Both sites run
  under the `R1BIO_Returned`/`R10BIO_Returned` guard, so the override fires exactly once; the
  override on the md-clone `master_bio` propagates to the real `orig_bio` via `md_end_clone_io`,
  `md.c:9406-9407`.)
- *Mixed-error precedence* (Finding N): real IO errors on other legs keep their handling; the
  P2P-error override still forces the master status; exclude the P2P leg from
  `narrow_write_error` (via the `bios[mirror] = NULL` above).
- `raid1_should_handle_error()` stays **upstream-unchanged** (it already returns false for
  `BLK_STS_INVAL`; the new arm sits in `*_end_write_request`, not in that predicate).

### 5.3 Self-heal — re-mirror the divergent range via the daemon (Findings L + O)
Because `dirty_bits` is process-context (Finding O), route the P2P-error r1_bio to the daemon
rather than completing inline:
1. **Reach the daemon.** `r1_bio_write_done()`/`one_write_done()` only `reschedule_retry()` on
   `R1BIO_WriteError` (`raid1.c:458`). Since the new arm must **not** set that flag (§5.2),
   extend the predicate to also reschedule on `R1BIO_P2PError`
   (`if (R1BIO_WriteError || R1BIO_P2PError) reschedule_retry(...)`), so the r1_bio reaches
   `raid1d`/`raid10d`. Without this change a pure P2P-error r1_bio would complete inline through
   the `else` (`close_write` + `raid_end_bio_io`) and never self-heal.
2. **Ordering is load-bearing — complete *first*, then dirty (corrects the §6 hazard).** The
   bitmap clear (`md_end_clone_io`→`end_write`, Finding L) fires *during* master-bio completion
   and is **unconditional**. So the daemon must, in this order: **(i)** snapshot `start`/`end`
   from the r1_bio; **(ii)** call `close_write()` (Finding R — balances `md_write_start`) and
   complete the master bio with the `BLK_STS_INVAL` override (§5.2) — this runs the unconditional
   `end_write`, driving the chunk counter to 0; **(iii) only then** call
   `mddev->bitmap_ops->dirty_bits(mddev, start, end)` on the snapshot, which now hits the
   canonical "newly dirty" path in `md_bitmap_set_memory_bits` (`*bmc==0 → *bmc = NEEDED_MASK|2`,
   `md-bitmap.c`) and rewinds `mddev->resync_offset` (`md-bitmap.c:1979`); **(iv)** `unplug`,
   `set_bit(MD_RECOVERY_NEEDED, &mddev->recovery)`, wake the sync thread. Doing `dirty_bits`
   *before* completion (as an earlier draft did) races the `end_write` decrement and relies on
   `NEEDED_MASK` surviving it — fragile; the complete-then-dirty order is race-free w.r.t. the
   clear. **Locking caveat (Finding O):** `dirty_bits`' only in-tree caller (`bitmap_store`) holds
   `mddev_lock`; the daemon does **not** and cannot. `md_bitmap_set_memory_bits` takes
   `counts.lock` internally, but the `resync_offset` write is unlocked — audit that no concurrent
   reconfig/resync can race it from daemon context before shipping.
3. The resync re-mirrors the dirty range from an in-sync leg using **kernel-allocated** sync
   pages (`sync_request_write`, `raid1.c:2370`) — transient, no device fault, no permanent
   bad-blocks; the bit clears once synced. `dirty_bits` exists on **both** bitmap backends
   (`bitmap_dirty_bits` `md-bitmap.c:3085`, `llbitmap_dirty_bits` `md-llbitmap.c:1782`).

---

## 6. Open items for the implementation plan

- **Stage the rollout:** fail-the-write (§5.2) closes the silent-success integrity hole on its
  own and is straightforward to get provably correct; the self-heal (§5.3) is the complex,
  hardware-only-verifiable half (ordering, counters, daemon locking). Consider shipping
  fail-the-write **first** and validating self-heal as a separate increment — they are cleanly
  separable. Note too that when the submitter honors the loud `BLK_STS_INVAL` and retries on a
  non-P2P/bounce path, that retry rewrites **both** legs and already converges the range; the
  in-kernel self-heal's distinct value is restoring leg-to-leg **consistency** when the submitter
  treats `INVAL` as fatal and does *not* retry.
- **One daemon path for both** the fail-the-write completion and the self-heal `dirty_bits` —
  design the `reschedule_retry` routing once, for raid1d **and** raid10d; remember the daemon arm
  owns `close_write()` (Finding R) and must reschedule on `R1BIO_P2PError` (§5.3 step 1).
- **`dirty_bits` vs the unconditional clear (resolved in §5.3 — verify on hardware):**
  `md_end_clone_io` (md.c:9395) clears the bit on completion (Finding L). §5.3's
  **complete-then-`dirty_bits`** order makes the forced bit land *after* that clear on a
  zeroed counter (canonical newly-dirty state) — confirm this holds on **both** bitmap backends
  and that the subsequent resync actually re-mirrors the range (the §7 test must observe the bit
  *and* a converged read, since source-presence can't).
- **`dirty_bits` daemon locking (Finding O):** its sole in-tree caller holds `mddev_lock`; the
  daemon does not. Audit `resync_offset`/reconfig races from daemon context.
- **No-bitmap configuration:** `dirty_bits` needs a bitmap. Without one, fall back to
  fail-the-write-only (submitter must retry); there is no in-kernel range tracker otherwise.
  Document this.
- **raid10 parity** (`raid10d`) and tests on **both** classic-bitmap and llbitmap.
- **`BLK_STS_INVAL` overload:** it is also returned for genuinely-invalid I/O (LBS/atomic
  bounds, `block/blk-core.c`). The `R1BIO_P2P`-bit guard narrows the new arm to P2P bios only;
  confirm a P2P bio can't *also* legitimately get `BLK_STS_INVAL` for a non-topology reason and
  thus get force-failed/healed spuriously (low risk; note it).
- **dkms gating + selftests:** extend `dkms/patches/0008-p2pdma-feature-flag-gating.patch` (on
  `meshstor-harness`) to `#ifdef HAVE_BLK_FEAT_PCI_P2PDMA` the new completion-path code; the new state
  bits and the daemon arm must compile out cleanly on pre-6.11. Update `test_0008`.

---

## 7. Testing — needs hardware (CI cannot)

Per Finding E, no loopback/`nvme-tcp` rig can exercise the kernel-native P2P path. A real test
needs:
- a P2P-capable second leg (`nvme-pci`, or `nvme-rdma`),
- a GPU whose pages are P2P-mappable (the GDS/RTX-4080 rig is sufficient for *correctness*;
  datacenter GPUs only matter for throughput certification),
- cuFile configured for the kernel-native path: `block.raid.use_pci_p2pdma` /
  `use_pci_p2pdma: true` in `cufile.json`, with `allow_compat_mode: false` (otherwise a failed
  true-P2P silently bounces through CPU and yields a **false pass**).

Validate: (1) the detector actually fires (the submit-flag path, not a dead clone check — the
exact bug class of Finding K); (2) a partial-reachability write fails loud with `BLK_STS_INVAL`
and faults nothing; (3) the divergent range re-mirrors and a subsequent read returns consistent
data on both legs; (4) **no `writes_pending` leak** after a P2P-error write — i.e. the array
still suspends/reshapes/idles afterward (`mdadm --action=frozen`, `echo frozen > sync_action`,
or a clean `mddev_suspend` via resize all complete); a missed `close_write` (Finding R) shows up
exactly here and nowhere in (1)-(3). Source-presence/compile selftests (`test_0008`) **cannot**
prove any of this — they only prove the code is wired and compiles (that is exactly how the dead
detectors shipped).

---

## 8. Rejected alternatives
- **Inline `dirty_bits` in the completion path** — unsafe; it's a sleeping, lock-held,
  process-context primitive (Finding O).
- **`rdev_set_badblocks` on the failed leg** — mislabels a healthy device region and
  accumulates bad blocks for a transient GPU↔device topology issue (the over-reaction option (c)
  rejects).
- **Option (b) swallow** — the silent-divergence integrity gap (§2); it's the current base
  behaviour this follow-up removes.
- **Detecting P2P-ness on the end_io clone** — dead code (`bi_vcnt==0`, Finding K).
