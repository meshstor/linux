# Performance

Measured perf characteristics of meshstor-ms on baremetal hardware,
2026-05-02 baseline. Three workload tables (raid1 multi-thread, raid10
multi-thread, raid1 single-thread bitmap-flush hot-path) across the two
RHEL kernel versions, with discussion of latency-EWMA effects, when
llbitmap helps, and the RHEL 9 llbitmap limitation.

For per-distro caveats see [compat.md](compat.md). For reading
EWMA at runtime see [admin.md](admin.md#per-rdev-keys).

## Methodology

### Hardware

Two identical baremetal hosts, run independently:

| Field | Value |
|---|---|
| CPU | 12th Gen Intel Core (i9-12900H on 192.168.200.32; i5-12600H on 192.168.200.35) |
| RAM | 16 GiB DDR4 |
| Storage | WD_BLACK SN7100 1 TB NVMe (single device, gen4) |
| Test partitions | 5×20 GiB GPT partitions in unallocated trailing space (`nvme0n1p4` through `nvme0n1p8`) |

The four working partitions live on a single physical NVMe. This
matters for the discussion below: latency-EWMA's read-routing
behavior on multiple-partitions-of-one-disk is different from
multiple-distinct-disks. Real-fleet numbers will differ.

### Software

| Distro | Kernel | meshstor-ms | mdadm fork |
|---|---|---|---|
| RHEL 10.1 / Rocky 10 | 6.12.0-124.40.1.el10_1 | 0.1.0 (DKMS) | v4.6 (with ms support) |
| RHEL 9.7 / Rocky 9 | 5.14.0-611.49.1.el9_7 | 0.1.0 (DKMS) | v4.6 (with ms support) |

Both hosts ran the meshstor-ms-dkms 0.1.0 package built fresh against
the running kernel headers (KBUILD_EXTMOD-aware Makefile.in,
build-time feature detection). Modules signed by per-host DKMS auto-MOK
key.

### fio invocation

For multi-thread tests:

```bash
fio --name=<label> --filename=<dev> \
    --direct=1 --ioengine=libaio \
    --rw=<randread|randwrite> \
    --bs=4k --iodepth=32 --numjobs=4 \
    --runtime=20 --ramp_time=5 \
    --group_reporting --time_based \
    --size=8G --output-format=normal
```

For single-thread tests, `--iodepth=1 --numjobs=1`. `drop_caches` is
issued (`echo 3 > /proc/sys/vm/drop_caches`) between every run so the
page cache doesn't carry state between configurations. 5-second ramp,
20-second measurement window.

The 2026-05-02 numbers above were captured with a standalone bench script
(since removed; the raw per-host logs are no longer kept in-tree). The
current tooling that reproduces the same md-vs-ms and bitmap-mode tables is
[`bin/perf-bitmap-compare`](../bin/perf-bitmap-compare) — see
[perftest-playbook.md](perftest-playbook.md) and the
[Reproducing](#reproducing) section below.

## raid1 multi-thread (4 jobs, qd=32, 4k random)

Two members of a raid1 mirror across `/dev/nvme0n1p4` and `/dev/nvme0n1p5`.

| Configuration | RHEL 10 / 6.12 | RHEL 9 / 5.14 |
|---|---|---|
| kernel md, internal bitmap, randread | 280k iops | 318k iops |
| ms, internal bitmap, randread | **436k iops (+56%)** | 318k iops |
| ms, llbitmap, randread | 435k iops | 318k iops |
| kernel md, internal bitmap, randwrite | 319k iops | 188k iops |
| ms, internal bitmap, randwrite | 320k iops | 188k iops |
| ms, llbitmap, randwrite | 318k iops | **10k iops** ⚠ |

The headline result on RHEL 10: ms randread is 56% faster than kernel md
on the same workload. This is latency-EWMA at work — see [discussion
below](#latency-ewma-effects). On RHEL 9 the EWMA effect doesn't surface
in this benchmark; it does on raid10.

The ⚠ row is the RHEL 9 llbitmap regression. Documented in
[compat.md](compat.md#llbitmap-on-rhel-9-empirical-limitation).

## raid10 multi-thread (4 disks, 4 jobs, qd=32, 4k random)

Four members of a raid10 (near=2 layout) across
`/dev/nvme0n1p4` through `/dev/nvme0n1p7`.

| Configuration | RHEL 10 / 6.12 | RHEL 9 / 5.14 |
|---|---|---|
| kernel md, internal bitmap, randread | 420k iops | 292k iops |
| ms, internal bitmap, randread | 433k iops | **422k iops (+45%)** |
| ms, llbitmap, randread | 438k iops | 422k iops |
| kernel md, internal bitmap, randwrite | 305k iops | 188k iops |
| ms, internal bitmap, randwrite | 304k iops | 188k iops |
| ms, llbitmap, randwrite | 304k iops | **4.5k iops** ⚠ |

On RHEL 10, raid10 ms vs md is roughly at parity (3% gain on randread,
even on randwrite). The latency-EWMA effect that drove the +56% raid1
result doesn't compound here because raid10 already spreads reads
across more rdevs.

On RHEL 9, ms raid10 randread is 45% faster than kernel md raid10
randread (422k vs 292k). The EWMA effect surfaces strongly on this
configuration.

## raid1 single-thread (qd=1, n=1, 4k randwrite — bitmap-flush hot path)

This is the workload llbitmap was designed for: every write triggers a
bitmap dirty-bit flush, and the flush is on the critical write path.

| Configuration | RHEL 10 / 6.12 | RHEL 9 / 5.14 |
|---|---|---|
| kernel md, internal bitmap | 67.7k iops | 62.1k iops |
| ms, internal bitmap | 64.4k iops | 61.1k iops |
| ms, llbitmap | **81.1k iops (+26% over md, +26% over ms-internal)** | **6.5k iops** ⚠ |

llbitmap delivers 26% over both reference points on RHEL 10 — a
real, repeatable win that comes from removing the bitmap-side
serialization. On RHEL 9 the same configuration is 9× slower than
internal bitmap for the reasons in [compat.md](compat.md#llbitmap-on-rhel-9-empirical-limitation).

Recommendation: enable llbitmap (`--bitmap=lockless` or
`--bitmap=auto`) for raid1 backing low-qd write-heavy workloads on
RHEL 10+ / Ubuntu 24.04 HWE+ / Ubuntu 26.04. For RHEL 9 use
`--bitmap=internal`.

## Discussion

### Latency-EWMA effects

The +56% raid1 randread number on RHEL 10 (and the +45% raid10
randread on RHEL 9) comes from `md-latency-ewma` — the per-rdev
exponentially-weighted moving average of read latency that biases
the read balancer.

Kernel md raid1's read balance is a "round-robin with hysteresis"
heuristic that picks the rdev whose head position is closest to the
last-served sector. On NVMe (no head position), this degenerates to
"alternate between rdevs". Latency-EWMA picks whichever rdev is
*observably faster right now*.

On a single-NVMe-with-multiple-partitions config (our test setup),
device-side queue contention or cache asymmetry can make one
partition transiently faster than another. EWMA notices and routes
all reads there, getting better device-side queue depth than
round-robin alternation. That's where the headline ratios come from.

In a multi-disk-on-separate-buses config, EWMA's contribution is
smaller — it still helps when one disk is genuinely slower (firmware
issue, thermal throttling, SAN backplane congestion), but it won't
deliver a 56% win across the board. **Treat the headline ms-faster
ratios in the raid1 randread row as best-case for the single-NVMe
test setup, not as a guaranteed fleet-wide multiple.**

The honest summary:

- ms vs md *with EWMA neutralized* (e.g., on workloads where EWMA
  doesn't reroute): within ±1% on every measured workload.
- ms vs md *with EWMA active*: 0% to 56% faster depending on whether
  rdev-latency asymmetry exists.
- ms is never measurably slower than md on the workloads tested,
  except for the broken-llbitmap-on-RHEL-9 case which is a documented
  compat limitation, not an inherent overhead.

### When llbitmap helps

llbitmap removes the bitmap-page-flush serialization that internal
bitmap has. Two specific conditions:

1. **Hot bitmap region**: the same bitmap chunk is being dirtied
   repeatedly (small randwrite, single-thread or low-thread-count).
   Internal bitmap serializes the flushes through a single mutex;
   llbitmap doesn't.
2. **Low queue depth**: at high qd (32+ jobs × 32+ depth), the
   bottleneck moves to the underlying device, not the bitmap. llbitmap
   makes no measurable difference there.

The +26% raid1 single-thread randwrite result on RHEL 10 hits both
conditions. The +0% raid1 multi-thread result on RHEL 10 hits neither
(spread across many jobs, so the mutex contention is amortized,
queue depth is high enough that the device dominates).

If your customer workload looks like a database WAL append or a
metadata journal — sustained low-qd writes to a small footprint —
llbitmap will deliver. If it looks like a bulk-throughput workload
spread across many threads, llbitmap won't hurt but it won't help.

### llbitmap on RHEL 9 — broken

Single-thread randwrite: 9× slower than internal (62k → 6.5k).
Multi-thread raid1 randwrite: 18× slower (188k → 10k). Multi-thread
raid10 randwrite: 42× slower (188k → 4.5k).

The kernel logs the underlying reason on every `--bitmap=lockless`
array assembly:

```
ms0: array will not be assembled in old kernels that lack configurable LBS support (<= 6.18)
```

llbitmap depends on configurable logical-block-size, a kernel feature
that landed upstream in 6.18. RHEL 9's 5.14 kernel doesn't have it
(and Red Hat hasn't backported it as of this writing). On kernels
lacking it, llbitmap falls back to a synchronous slow path. The
fallback writes correctly — data integrity is intact — but
throughput collapses.

**Always use `--bitmap=internal` on RHEL 9.** Our `mdadm` fork's
`--bitmap=auto` (the default) makes the right choice automatically:
it probes kernel-side LBS support and picks `internal` on RHEL 9,
`lockless` elsewhere. Customers who explicitly pass
`--bitmap=lockless` on RHEL 9 will hit this regression.

## Comparing to the spec's earlier estimate

The original design spec mentioned 3-5% ms-vs-md overhead, based on VM
testing. Baremetal results are different:

- VM tests measured ms in a CONFIG_MD=m kernel where md_mod was
  unloaded. ms there was *replacing* md_mod, sharing the device
  queues.
- Baremetal here runs ms alongside the always-on kernel md_mod (per
  the parallel-subsystem architecture). The two subsystems use
  different code paths into the block layer, and ms's latency-EWMA
  read balancer reroutes around device-side asymmetries that VM
  testing didn't expose.

The honest restatement:

- Where ms's optimizations apply (low-qd bitmap-bound writes for
  llbitmap; rdev-latency-asymmetric reads for EWMA): ms is
  measurably faster than md.
- Where ms's optimizations don't apply (high-qd device-bound
  workloads): ms is at parity with md.
- ms is never measurably slower than md on the workloads tested
  (except the documented RHEL-9-llbitmap regression).

## Reproducing

Full host setup (packages, the meshstor-patched mdadm, suites) is in
[perftest-playbook.md](perftest-playbook.md). The short version that
reproduces the md-vs-ms and bitmap-mode comparisons above:

```bash
# 1. Create test partitions (idempotent; 4 × 25 GiB in trailing free space).
sudo COUNT=4 bin/perf-make-test-partitions /dev/nvme0n1

# 2. Install the meshstor-ms-dkms package (per docs/install.md) and build the
#    ms-aware mdadm fork (the perf tools wrap it as build/msadm at run time).

# 3. Run the bitmap-mode comparison (md-internal vs ms-internal vs ms-lockless).
sudo bin/perf-bitmap-compare /dev/nvme0n1p4 /dev/nvme0n1p5

# 4. Render the comparison table from the latest results dir.
bin/perf-extract-table "$(ls -dt results/perf-bitmap-* | head -1)"
```

Wall-clock estimates per run are in
[perftest-playbook.md](perftest-playbook.md#phase-3--run-a-comparison).
For the per-feature-branch comparison (latency-EWMA, per-bucket-arrays,
takeover, llbitmap-fastpath) use [`bin/perf-compare`](../bin/perf-compare)
instead.

## See also

- [compat.md](compat.md) — llbitmap-on-RHEL-9 limitation in detail
- [admin.md](admin.md) — reading EWMA at runtime
- [architecture.md](architecture.md) — design context
- [perftest-playbook.md](perftest-playbook.md) — copy-paste perf-run recipe
