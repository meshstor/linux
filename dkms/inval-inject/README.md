# inval-inject — blk_status completion injector (test only)

Rewrites a member **data write** completion's `blk_status_t` at
`raid1_end_write_request` (raid1_ms) or `raid10_end_write_request`
(raid10_ms) entry, for exactly one gendisk (`disk=`, `partno=`).

Two rig shapes use it:

- **P6 (narrowness proof)** — `match=ioerr` (default) + dm-flakey
  `error_writes` under one leg: the write never reaches media and completes
  `BLK_STS_INVAL`. Stage-1 keys on the `R1BIO_P2P` bit, so a **non-P2P**
  INVAL keeps upstream's swallow semantics (silently counted as success,
  leg stale) — P6 asserts exactly that, plus the absence of the stage-1
  "no P2P path" breadcrumb.
- **P7 (stage-1 arm on real GPU I/O)** — `match=success to_status=inval|target
  p2p_only=1`: data reaches media, the status is rewritten on completion,
  and the era-keyed stage-1 arm must fail the write loud (EINVAL to the
  submitter, no leg fault, no badblocks, breadcrumb in dmesg).

## Parameters

| param | default | meaning |
|---|---|---|
| `symbol=` | `raid1_end_write_request` | probe target; **module-qualified `mod:name` form** (`raid1_ms:raid1_end_write_request`, `raid10_ms:raid10_end_write_request`) resolves within that module only |
| `disk=` | (none) | gendisk name of the target member (`nvme0n1`, `dm-0`) |
| `partno=` | -1 | partition to match (-1 any, 0 whole disk) |
| `match=` | `ioerr` | rewrite completions that failed IOERR / succeeded (`success`) / `any` |
| `to_status=` | (empty = `inval`) | `inval` \| `target` \| numeric blk_status |
| `p2p_only=` | auto | rewrite only bios carrying PCI P2PDMA (GPU BAR) pages; defaults 0 for `match=ioerr`, 1 otherwise |
| `remaining` | 0 | rw budget; `echo N > /sys/module/inval_inject/parameters/remaining` arms |
| `injected` | 0 | ro counter of rewrites |

## The module-qualified symbol rule

`raid1_end_write_request` exists in BOTH in-tree `raid1.ko` and `raid1_ms.ko`;
with both loaded a bare-name kprobe can silently bind to the wrong module and
never fire (observed live). In-kernel multiplicity detection is not
implementable (the kallsyms enumeration helpers are unexported), so init
**refuses to load** with a bare `symbol=` whenever `match != ioerr`,
`to_status=` is set, or `p2p_only=1`. Callers additionally run the userspace
ambiguity check (`gds_kallsyms_check` in gds/lib.sh) before insmod. The
`mod:name` form is resolved by kallsyms (`module_kallsyms_lookup_name`)
within the named module.

## Interception scope / hazards

- Only per-leg **data** write completions traverse the probed functions.
  Superblock/bitmap writes go via `md_write_metadata()` with their own rdev
  end_io — `match=success` cannot poison CSI-shape bitmap/SB traffic. (Do
  not port the QEMU suite's dm-errstat REQ_META exemption here: that
  injector sat *below* md and saw everything; the kprobe point is
  structurally immune.)
- **XFS traffic is NOT exempt**: cuFile registers files on mounted XFS, so
  journal/metadata writes traverse the probe while armed. A plain write
  rewritten to TARGET faults a FailFast leg via `md_error()`; a plain INVAL
  is silently swallowed (stale leg). Every arming on a mounted-fs rig must
  use `p2p_only=1`.
- The P2P filter reads `bio->bi_io_vec->bv_page` on the leg clone directly:
  at completion `bi_iter.bi_size` is 0 (`bio_has_data()` false) but the
  clone's bvecs alias the master bio's, and the master outlives leg
  completions in the raid1/raid10 write paths. The raid10 repl-bio path is
  NOT exercised — no replacement devices are configured in any campaign
  rig; re-verify before arming on a replacement-carrying array.
- Module unload kills kprobes (`KPROBE_FLAG_GONE`): each test owns a full
  insmod → arm → disarm → rmmod cycle; never reuse a loaded instance across
  a module swap.
- `injected`/`remaining` updates are unsynchronized — acceptable for a rig.

Plain kbuild (`make`, `make clean`); deliberately NOT a dkms package — it is
loaded ad-hoc by tests and must never auto-rebuild or ship.

## 6.17 API notes

`bdev_partno()` accessor (no `bd_partno` field on 6.17), `<asm/ptrace.h>`
included directly for `regs_get_kernel_argument()`,
`is_pci_p2pdma_page()` from `<linux/memremap.h>`.
