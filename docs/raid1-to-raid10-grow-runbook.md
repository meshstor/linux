# Runbook: in-place raid1 → raid10 → grow with a live XFS filesystem

This runbook walks an admin through doubling the usable capacity of a
mirrored volume *without unmounting it*:

1. Start with a 2-disk `raid1` carrying a mounted XFS filesystem.
2. Convert the array in place to `raid10_near(2,2)` — same capacity,
   same data, same mount point.
3. Add two more disks and reshape to `raid10_near(4,2)` — capacity
   doubles, data preserved.
4. `xfs_growfs` claims the new space, still mounted.

All steps run on a live volume. The filesystem stays online and serves
reads and writes throughout.

> **Read this first:** the section [What you didn't
> get](#what-you-didnt-get) at the bottom enumerates every mdadm,
> mkfs.xfs and mount option that this in-place path leaves at less
> than the value a fresh-format would have used. If that mismatch
> matters to you, format from scratch instead — see [When this
> runbook is the wrong tool](#when-this-runbook-is-the-wrong-tool).

---

## Prerequisites

* The `ms_mod`, `raid1_ms` and `raid10_ms` kernel modules are loaded.
  Verify with `lsmod | grep -E '^ms_mod|^raid1_ms|^raid10_ms'`.
* The patched `mdadm` is in your `$PATH` as `msadm` (a one-line shell
  wrapper that always passes `--subsys=ms`):

  ```sh
  cat > /usr/local/sbin/msadm <<'EOF'
  #!/bin/sh
  exec /path/to/patched/mdadm --subsys=ms "$@"
  EOF
  chmod +x /usr/local/sbin/msadm
  ```

* Four block devices of equal size are available. Examples in this
  document use `/dev/nvme0n1p4` through `/dev/nvme0n1p7` (~26 GiB each
  in our test rig). Substitute your own.
* `xfsprogs` is installed (`mkfs.xfs`, `xfs_growfs`).
* You are root, or prefix every command with `sudo`.

---

## Procedure

### Step 1 — Create the 2-disk raid1

```sh
sudo msadm --create --run --metadata=1.2 --level=1 \
    --raid-devices=2 /dev/ms127 /dev/nvme0n1p4 /dev/nvme0n1p5
```

Wait for the initial resync to drain. `msadm --wait` returns early on
the lockless framework, so poll `sync_action`:

```sh
while [ "$(sudo cat /sys/block/ms127/ms/sync_action)" != idle ]; do
    sleep 1
done
echo "raid1 ready, size=$(sudo blockdev --getsize64 /dev/ms127) bytes"
```

A 26 GiB volume takes ~2 minutes on NVMe.

### Step 2 — Format XFS (raid1-shape)

The CSI `FormatXFS` flag set, with raid1-appropriate dynamic options
(no `-d su/sw`, no `-l su`; `agcount=16` because the volume is between
1 GiB and 80 GiB; no `-l size=1g` because we are below the 40 GiB
threshold):

```sh
sudo mkfs.xfs -f \
    -s size=4096 \
    -b size=4096 \
    -i size=512 \
    -m crc=1,finobt=1,reflink=0,rmapbt=0,bigtime=1,inobtcount=1 \
    -d agcount=16 \
    -l internal,version=2,lazy-count=1 \
    /dev/ms127
```

### Step 3 — Mount with the CSI mount options

```sh
sudo mkdir -p /mnt/ms127
sudo mount -t xfs \
    -o noatime,nodiratime,logbufs=8,logbsize=256k,inode64,noquota \
    /dev/ms127 /mnt/ms127

findmnt -no SOURCE,FSTYPE,OPTIONS /dev/ms127
df -hT /mnt/ms127
```

### Step 4 — Write payload (proves byte-identity later)

```sh
sudo dd if=/dev/urandom of=/mnt/ms127/payload bs=1M count=128 oflag=direct
sync
sudo md5sum /mnt/ms127/payload | sudo tee /mnt/ms127/.sum
```

### Step 5 — Take over raid1 → raid10 **while mounted**

```sh
sudo msadm --grow --level=10 /dev/ms127
while [ "$(sudo cat /sys/block/ms127/ms/sync_action)" != idle ]; do
    sleep 0.5
done
```

The personality swap is byte-identical: no data moves. Expect
`/sys/block/ms127/ms/level` to flip to `raid10`, layout `258`
(`near=2, raid_disks=2`), `chunk_size` `524288` (the takeover helper's
512 KiB default), and the same `array_size`.

Verify data is intact:

```sh
sudo md5sum -c /mnt/ms127/.sum
```

### Step 6 — Add the new pair and reshape to 4 disks **while mounted**

```sh
sudo msadm --add  /dev/ms127 /dev/nvme0n1p6 /dev/nvme0n1p7
sudo msadm --grow --raid-devices=4 /dev/ms127

while [ "$(sudo cat /sys/block/ms127/ms/sync_action)" != idle ]; do
    sleep 2
done
```

The reshape is a real data-movement operation (raid_disks goes from 2
to 4, layout stays `near=2`). For a 26 GiB volume on the test rig it
takes ~4–5 minutes at the kernel default reshape rate (rate-limited by
`/proc/sys/dev/raid/speed_limit_max`, not the disks).

Verify:

```sh
sudo md5sum -c /mnt/ms127/.sum
sudo cat /sys/block/ms127/ms/raid_disks   # 4
sudo blockdev --getsize64 /dev/ms127      # ~2x what it was
```

### Step 7 — `xfs_growfs`

The block device is bigger now; the filesystem is not. Grow it (still
mounted):

```sh
df -h /mnt/ms127          # still old size
sudo xfs_growfs /mnt/ms127
df -h /mnt/ms127          # ~2x larger
sudo md5sum -c /mnt/ms127/.sum
```

Done. The filesystem was mounted and serving IO from Step 3 all the
way through Step 7.

---

## What you didn't get

This is the section to read carefully. Going in-place is a real
trade-off: several mdadm, mkfs.xfs and mount-option choices that
matter for a tuned, from-scratch CSI volume **are not applied** by
this procedure. Most are silent — `mount` does not warn you, `df` does
not warn you, and the filesystem will work fine. They affect
throughput, latency and metadata layout, not correctness.

### mdadm: chunk size is 512 KiB, not 64 KiB

The CSI creates raid10 with `--chunk=64` so that XFS stripe alignment
matches the raid chunk exactly. The kernel takeover helper does not
inherit a chunk from raid1 (raid1 has none) and picks `512 KiB` as a
generic default, matching mdadm's own default for fresh raid10.

* **What you have now:** `/sys/block/ms127/ms/chunk_size = 524288`
* **What a fresh CSI raid10 has:** `chunk_size = 65536`
* **Impact:** stripe-aligned writes are still aligned, but the unit is
  8× larger. Workloads that issue many small writes at random offsets
  do not benefit from the smaller chunk's lower write-amplification.
  Workloads that issue large sequential writes are unaffected (the
  stripe is striped either way).

There is no in-place way to change the chunk size on an existing
raid10 — you would have to copy data off, recreate with
`--chunk=64`, copy back.

### mdadm: layout is locked to near=2

The takeover helper chooses `near_copies = 2, raid_disks = N` and
forces `near=2` to stay through the grow. You cannot ask for
`far=2`, `offset=2`, or `near=3` along this path.

* **What you have now:** `layout = 258` = `(1 << 8) | 2`
* **What CSI uses:** also `near=2` (so this matches), but admins who
  want a different replica layout for a different durability profile
  must format from scratch.

### mdadm: bitmap carries over from raid1

Whatever bitmap the source raid1 had is what the resulting raid10 has.
If you created the raid1 without `--bitmap=internal`, the raid10 has
no bitmap and a future degraded resync replays the entire array
instead of just the dirty regions.

* **Check:** `ls /sys/block/ms127/ms/bitmap/` — empty/absent means no
  bitmap.
* **Fix after the fact (still mounted):**
  `sudo msadm --grow --bitmap=internal /dev/ms127`

### XFS: stripe geometry is NOT carried into the on-disk metadata

This is the largest silent gap. `mkfs.xfs` in Step 2 was given
**no `-d su=…,sw=…` and no `-l su=…`** because at format time the
device was a raid1 with no exposed stripe geometry (raid1 does not
have one). After Step 6 the device IS striped (chunk = 512 KiB,
sw = 2), but XFS has no way to learn that:

* `xfs_growfs` only changes block counts; it does not rewrite the
  superblock's stripe fields.
* `xfs_info /mnt/ms127` will keep reporting `sunit=0 swidth=0` until
  you reformat.

**What this costs you:**

* The XFS allocator no longer rounds large allocations to the stripe
  width. Files larger than 512 KiB land at arbitrary offsets within
  the stripe, so a single application read can straddle two mirror
  pairs that were on different disks. With small files this is fine;
  with large sequential workloads it sacrifices some prefetch and
  cache locality.
* The journal does not stripe-align its log writes (it would have if
  `-l su=4096` had been set). Small fsync-driven log writes can
  trigger read-modify-write on a striped device. The CSI explicitly
  pins `-l su=4096` for this reason.

**There is no in-place fix.** Once an XFS is on disk without stripe
geometry, the only way to get it is `xfs_dump` → `mkfs.xfs` with
`-d su=512k,sw=2 -l su=4096` → `xfs_restore`.

### XFS: agcount is 16, not 32

CSI uses `agcount=32` for raid10 (rationale: ~one AG per hardware
thread, plus AG count fixed at format time). We used `agcount=16`
because the volume was a raid1 at format time. After the grow to
raid10 with double the capacity, agcount is still 16.

* **Impact:** half as many independent allocation streams as a CSI
  raid10. Concurrent writers may queue behind each other in the AG
  allocator under high parallelism (32+ concurrent writer threads).
  At lower parallelism the difference is unmeasurable.

### XFS: log size is auto-sized (~58 MiB), not 1 GiB

CSI explicitly sets `-l size=1g` for raid10 once the volume is large
enough that the log fits comfortably (≥ 80 GiB). Our test volume at
52 GiB is below that threshold, so mkfs auto-sized the log. Even on
larger volumes formatted via this procedure, the log auto-sized at
raid1 time (when only 26 GiB) will be even smaller than the raid10
auto-size would have produced.

* **Check:** `xfs_info /mnt/ms127` → look at the `log = internal log`
  block count.
* **Impact:** under heavy metadata bursts (many concurrent
  create/unlink/rename), the journal may force-flush more often.
  Steady-state workloads are not affected.

### Mount: kernel adds options you didn't ask for

`findmnt -no OPTIONS /dev/ms127` will report several options you did
not pass to `mount -o`. These are kernel defaults, not bugs:

* `attr2` — extended-attribute format v2; XFS default since 5.10. CSI
  used to set this explicitly but stopped doing so (it is now noise).
* `seclabel` — added when SELinux is enabled. Harmless.
* `sunit=N,swidth=M` — the kernel reads the on-disk geometry. For a
  filesystem made via this procedure these read `sunit=0,swidth=0`
  (see above). A from-scratch CSI volume shows `sunit=128,swidth=256`
  (in 512-byte units) — i.e. 64 KiB × 2.

### Mount: options CSI deliberately omits, also missing here

If you copy a `mount` line from somewhere else on the internet, you
may be tempted to add these. CSI's `BuildMountOptions` rejects each
one for a documented reason. This runbook also does not set them:

| Option | Why CSI rejects it |
|---|---|
| `largeio` | inflates `st_blksize`, causes read amplification |
| `swalloc` | rounds every extension to stripe-width, wastes space on small files |
| `allocsize=…` | disables XFS dynamic preallocation; can cause GB-scale `df` bloat |
| `filestreams` | spreads one file per AG; wrong direction for concurrent writes |
| `wsync` | forces synchronous metadata; 5–20× regression on OLTP |
| `nobarrier` | removed in kernel 4.19; mount now fails |
| `discard` | inline trim hurts tail latency; use periodic `fstrim` |
| `norecovery` | skips log replay, never for live filesystems |
| `nouuid` | only for mounting LVM snapshot clones |

---

## When this runbook is the wrong tool

Use this in-place procedure when:

* You have a live volume that must stay online during the upgrade.
* The mismatch costs listed above are acceptable for your workload
  (typical: dev / staging / non-latency-critical production).

Format from scratch when:

* Throughput predictability under heavy random-write workloads matters.
* The volume hosts an OLTP-style database where journal stripe
  alignment is on the critical path.
* You are within a planned maintenance window with backup capacity to
  hold the data while you `mkfs.xfs` fresh.

The fresh-format equivalent (CSI's normal path) is:

```sh
sudo msadm --create --run --metadata=1.2 --level=10 --raid-devices=4 \
    --chunk=64 --layout=n2 --bitmap=internal \
    /dev/ms127 /dev/nvme0n1p4 /dev/nvme0n1p5 /dev/nvme0n1p6 /dev/nvme0n1p7
# wait sync_action=idle
sudo mkfs.xfs -f \
    -s size=4096 -b size=4096 -i size=512 \
    -m crc=1,finobt=1,reflink=0,rmapbt=0,bigtime=1,inobtcount=1 \
    -d su=64k,sw=2,agcount=32 \
    -l internal,version=2,lazy-count=1,su=4096 \
    /dev/ms127
sudo mount -t xfs \
    -o noatime,nodiratime,logbufs=8,logbsize=256k,inode64,noquota \
    /dev/ms127 /mnt/ms127
```

Restore your data into `/mnt/ms127` from backup.

---

## Tested on

This procedure was validated on:

* Kernel 6.12.0-124.49.1.el10_1.x86_64 (RHEL 10.1)
* `ms_mod` + `raid1_ms` + `raid10_ms` from the
  `takeover` branch (commits including the
  `narrow takeover recovery check to MD_RECOVERY_RUNNING` fix —
  without it, `msadm --grow --level=10` in Step 5 fails with
  "recovery state not clean").
* 4 × 25.9 GiB NVMe partitions.

Timings observed: raid1 initial resync 136 s, takeover 0 s,
reshape 2 → 4 disks 271 s, `xfs_growfs` < 1 s. Total downtime: **0 s**.
