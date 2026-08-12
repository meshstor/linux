# inval-inject — BLK_STS_INVAL completion injector (test only)

Rewrites a member write completion from `BLK_STS_IOERR` to `BLK_STS_INVAL` at
`raid1_end_write_request` entry, for exactly one gendisk (`disk=`, `partno=`).
Paired with dm-flakey `error_writes` under that leg it reproduces the P2PDMA
partial-reachability completion (write never reaches media, status INVAL) that
the current base swallows — the silent-divergence gap in the p2pdma follow-up
spec (§2, Finding L). Used by
`tools/testing/selftests/md/p2pdma/gds/test_divergence_inval.sh`.

Plain kbuild (`make`, `make clean`); deliberately NOT a dkms package — it is
loaded ad-hoc by one test and must never auto-rebuild or ship.

Caveats: `symbol=raid1_end_write_request` resolves via kallsyms; the test
refuses to run while the in-tree `raid1` module is loaded (duplicate symbol).
The `injected`/`remaining` updates are unsynchronized — acceptable for a rig.

## 6.17 API drift fixed in this build

`struct block_device` no longer has a `bd_partno` field on kernels this new
(the partition number is packed into `__bd_flags`); the module uses the
`bdev_partno()` accessor from `<linux/blkdev.h>` instead of
`bio->bi_bdev->bd_partno`. `regs_get_kernel_argument()` lives in
`<asm/ptrace.h>`, which is not reliably pulled in transitively by
`<linux/ptrace.h>` alone, so the module includes `<asm/ptrace.h>` directly.
