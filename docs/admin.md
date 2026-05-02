# Operator runbook

Day-to-day operation, monitoring, recovery, and troubleshooting for
meshstor-ms. Assumes the package is already installed
(see [install.md](install.md)) and that you have an `ms`-aware
`mdadm` fork (or wrapper) in your `$PATH` as `msadm`.

For the underlying design and vocabulary, see
[architecture.md](architecture.md). For per-distro support and bitmap
selection caveats, see [compat.md](compat.md). For perf characteristics,
see [performance.md](performance.md).

## Loading and unloading the modules

The three meshstor-ms modules load in dependency order: `ms_mod` first
(provides the framework + bitmap_ops registrations), then the personality
modules `raid1_ms` and `raid10_ms` (each registers a level via
`register_ms_personality`).

```bash
sudo modprobe ms_mod
sudo modprobe raid1_ms
sudo modprobe raid10_ms

lsmod | grep -E '^ms_mod|^raid1_ms|^raid10_ms'
```

Expected:

```
raid10_ms              86016  0
raid1_ms               65536  0
ms_mod                294912  2 raid10_ms,raid1_ms
```

To unload (no arrays must be running):

```bash
sudo rmmod raid10_ms raid1_ms ms_mod
```

The `dmesg` signposts to look for after first `modprobe ms_mod`:

```
ms: registered device <major>:0 (dynamic)
md: raid1 personality registered for level 1
md: raid10 personality registered for level 10
```

(The `md:` prefix on personality registration messages comes from the
upstream personality init code which we did not rename — those messages
go through the same kernel `pr_info` path the kernel md uses, with no
per-subsystem prefix. The `ms:` prefix shows on subsystem-level messages
that the rename pass touched.)

## Inspecting state

### `/proc/msstat`

The parallel of `/proc/mdstat`. Shows registered personalities at the
top and one stanza per active array.

Empty state (modules loaded, no arrays):

```
Personalities : [raid1] [raid10]
unused devices: <none>
```

With one raid1 array:

```
Personalities : [raid1] [raid10]
ms0 : active raid1 loop1[1] loop0[0]
      261120 blocks super 1.2 [2/2] [UU]
      bitmap: 1/1 pages [4KB], 65536KB chunk

unused devices: <none>
```

Read it as: `<device> : <state> <level> <member>[role]…` followed by
size, superblock version, member count and per-member health
(`[UU]` = both up, `[U_]` = second member down, etc.), and the
bitmap configuration line.

### `/sys/block/msN/ms/` hierarchy

The sysfs root for an `ms` array `/dev/msN` is `/sys/block/msN/ms/`
(parallel of kernel md's `/sys/block/mdN/md/`). Captured live from
the RHEL 10 reference host:

```
/sys/block/ms0/ms/array_size
/sys/block/ms0/ms/array_state           # clean | active | readonly | ...
/sys/block/ms0/ms/bitmap/                # subdir, internal-bitmap stats
/sys/block/ms0/ms/bitmap_type            # none | bitmap | llbitmap
/sys/block/ms0/ms/chunk_size
/sys/block/ms0/ms/component_size
/sys/block/ms0/ms/consistency_policy
/sys/block/ms0/ms/degraded               # count of failed members
/sys/block/ms0/ms/dev-loop0/             # subdir, per-rdev (one per member)
/sys/block/ms0/ms/dev-loop1/
/sys/block/ms0/ms/level                  # 1, 10, ...
/sys/block/ms0/ms/logical_block_size
/sys/block/ms0/ms/metadata_version       # e.g. 1.2
/sys/block/ms0/ms/raid_disks
/sys/block/ms0/ms/rd0 → dev-loop0/       # symlinks by slot index
/sys/block/ms0/ms/rd1 → dev-loop1/
/sys/block/ms0/ms/sync_action            # idle | check | repair | resync | ...
/sys/block/ms0/ms/sync_speed
/sys/block/ms0/ms/uuid
```

Each entry's purpose:

- `array_state` — read/write toggle. Writing `idle` quiesces I/O.
- `bitmap_type` — current selection. Reads as a list with the active
  one in brackets, e.g., `none [bitmap] llbitmap` means "internal
  bitmap is active; `none` and `llbitmap` are the other supported
  values".
- `degraded` — non-zero means at least one member has failed.
- `level` — current personality level.
- `sync_action` — what the resync engine is doing right now. Write
  one of the supported strings to trigger an action (`check`,
  `repair`, etc.).
- `dev-<name>/` — per-rdev subdirectory; `<name>` is the underlying
  block device's name (e.g., `dev-loop0`, `dev-nvme0n1p4`).

### Per-rdev keys

Each `/sys/block/msN/ms/dev-<name>/` exposes:

- `state` — comma-separated flags, e.g., `in_sync,write_mostly`.
- `errors` — read-error counter for this rdev. Increments when a
  read fails; reset by `mdadm --re-add` or by writing 0.
- `latency_ewma_ns` — exponentially-weighted moving average of read
  latency in nanoseconds, updated continuously by the
  latency-EWMA feature. Used by raid1's read-balance code to bias
  reads toward whichever rdev is faster.
- `slot` — position in the array (0, 1, …).
- `size` — usable bytes on this rdev.
- `bad_blocks` / `unacknowledged_bad_blocks` — bad-block log.
- `recovery_start` — sector position during recovery; `none` when
  not recovering.

Reading `latency_ewma_ns` on a quiescent array returns a baseline
value (~25-100 µs for NVMe). Under load, the value tracks per-rdev
latency in real time. If two members of a raid1 mirror diverge
substantially (one becomes 10× slower than the other under contention),
the read balancer will route most reads to the faster member until
the EWMA evens out.

## Bitmap selection

Three bitmap types, selected at array-create time via `--bitmap=`:

| `--bitmap=` | What it does | When to use |
|---|---|---|
| `internal` | Classic md bitmap. Bitmap pages stored in the superblock area; flushes serialize writes through a single page-flush mutex. Works on every supported kernel. | Always works. Required on RHEL 9 (5.14) — see [compat.md](compat.md#llbitmap-on-rhel-9-empirical-limitation). |
| `lockless` | llbitmap. Lockless bitmap with hot-write fast-path optimization. Single-thread randwrite ~26% faster than `internal` on RHEL 10. | RHEL 10+, Ubuntu 24.04 HWE+, Ubuntu 26.04. **Do not use on RHEL 9** (9-42× slower). |
| `auto` | Picks `lockless` if the kernel supports configurable LBS, else `internal`. Default in our `mdadm` fork. | Recommended default — gets the right behavior on every supported platform. |

Confirm what's active on a running array:

```bash
cat /sys/block/ms0/ms/bitmap_type
# none [bitmap] llbitmap     ← active selection in brackets
```

The legacy term "bitmap" in this output refers to the internal bitmap.

## raid1 ↔ raid10 takeover

The takeover converts a 2-disk raid1 mirror into a 4-disk raid10 array
(near=2 layout) by adding two new members and reshuffling. It runs
online — the array stays accessible during the transition.

```bash
# Starting state: 2-disk raid1 on /dev/ms0.
sudo /tmp/msadm --grow /dev/ms0 \
    --level=10 \
    --raid-devices=4 \
    --add /dev/sdc /dev/sdd

# Watch progress:
watch -n 1 cat /proc/msstat
```

During the takeover window, the array runs degraded — a single-member
failure during the reshape can lose data. Schedule the operation when
no member-failure event is in flight, and ensure a recent backup
exists.

The reverse takeover (raid10 → raid1) is not supported online; convert
the array offline by re-creating from a subset of members.

## Coexistence with kernel md (operator-side)

Both subsystems are loaded by default on every supported distro:

- Kernel `md_mod` is built into `vmlinux`, always live.
- `ms_mod.ko` is DKMS-installed, loaded on first `modprobe ms_mod` or
  by udev/dracut on boot if a partition with the ms magic is found.

Run them concurrently:

```bash
# Create a kernel-md raid1 on two devices:
sudo mdadm --create /dev/md0 --level=raid1 --raid-devices=2 \
    --metadata=1.2 --bitmap=internal --run /dev/sda /dev/sdb

# Create an ms raid10 on four other devices:
sudo /tmp/msadm --create /dev/ms0 --level=raid10 --raid-devices=4 \
    --metadata=1.2 --bitmap=auto --run /dev/sdc /dev/sdd /dev/sde /dev/sdf

# Both report independently:
cat /proc/mdstat   # kernel md
cat /proc/msstat   # meshstor-ms
```

### Migrating an array between subsystems

Because both subsystems use the same on-disk superblock format, you
can stop an array under one and reassemble it under the other:

```bash
# Move a kernel-md array to meshstor-ms:
sudo mdadm --stop /dev/md0
sudo /tmp/msadm --assemble /dev/ms0 /dev/sda /dev/sdb

# And back:
sudo /tmp/msadm --stop /dev/ms0
sudo mdadm --assemble /dev/md0 /dev/sda /dev/sdb
```

The disks themselves are not modified by the move (no superblock
rewrite), so the migration is reversible at any point. See
[architecture.md](architecture.md#coexistence-model) for why this
works at the format level.

## Troubleshooting

### `modprobe ms_mod` fails or hangs

Check `dmesg` first:

```bash
sudo dmesg | tail -30
```

Common patterns:

- **`Lockdown is enabled. Loading of unsigned module is rejected.`**
  Secure Boot is on with `lockdown=integrity`. Either enroll the MOK
  key (Path 1 in [install.md](install.md#path-1-dkms-rebuild--auto-mok-default))
  or boot with `mokutil --disable-validation` (one-shot, requires
  reboot + MokManager confirmation).

- **`No such file or directory` from modprobe.** The package's modules
  weren't installed, or were installed for a different kernel. Check
  `dkms status`:

  ```bash
  sudo dkms status
  # Should report:  meshstor-ms/0.1.0, <KVER>, x86_64: installed
  ```

  If it reports `built` but not `installed`, run `sudo dkms install
  meshstor-ms/0.1.0`. If it reports nothing, reinstall the package.

- **Hang with no error, kernel becomes unresponsive.** Specific to
  RHEL 9.x historical builds where the sysctl-sentinel patch wasn't
  applied. Confirm by booting with `kdump` enabled and capturing the
  panic. The fix is in
  [`dkms/patches/0004-sysctl-table-sentinel-pre-6.4-compat.patch`](../dkms/patches/0004-sysctl-table-sentinel-pre-6.4-compat.patch);
  see [maintainer.md](maintainer.md#the-sysctl-sentinel-patch-case-study)
  for the case study.

### DKMS build failed

Look at the build log:

```bash
sudo cat /var/lib/dkms/meshstor-ms/<VER>/<KVER>/<ARCH>/log/make.log
```

Common patterns:

- **Compiler errors against kernel headers.** The feature-flag
  detection in `dkms/Makefile.in` should auto-adapt; if it doesn't,
  the issue is usually a brand-new compat gap on a kernel released
  after the package was published. File an issue with the make.log
  attached. As a workaround, downgrade to the previously-tested
  kernel (`grub2-set-default` to a prior entry).

- **`make: *** No targets.  Stop.`** Indicates a broken Makefile
  guard (KBUILD_EXTMOD missing). Should not occur with a pristine
  package — only if a maintainer locally edited
  [`dkms/Makefile.in`](../dkms/Makefile.in). See
  [maintainer.md](maintainer.md#the-kbuild_extmod-gotcha).

- **Signing failed.** DKMS attempted to sign with a missing or
  invalid key. Check `/var/lib/dkms/mok.key` exists and is readable;
  if not, `sudo dkms autoinstall --force` regenerates it.

### Array does not appear after reboot

Check, in order:

```bash
# 1. Modules loaded?
lsmod | grep ^ms_mod

# 2. dkms confirms install?
sudo dkms status | grep meshstor-ms

# 3. mdadm.conf has an ARRAY line for the ms-bound array?
grep ms /etc/mdadm.conf /etc/mdadm/mdadm.conf 2>/dev/null

# 4. Partitions with ms magic visible?
sudo /tmp/msadm --examine /dev/sd* 2>/dev/null | grep -E 'Magic|Array UUID'
```

If `dkms autoinstall` is enabled (the default in our `dkms.conf.in`),
modules rebuild after every kernel upgrade automatically. If not, the
post-upgrade kernel boots without our modules and arrays don't assemble.

To assemble manually after a kernel change:

```bash
sudo dkms autoinstall
sudo modprobe ms_mod raid1_ms raid10_ms
sudo /tmp/msadm --assemble --scan
```

### Kernel oops on first modprobe (RHEL 9)

RHEL 9.x kernels (5.14) trigger a `sysctl_check_table` panic on
`modprobe ms_mod` if the sysctl-sentinel compat patch isn't applied.
This is fixed by patch
[`dkms/patches/0004-sysctl-table-sentinel-pre-6.4-compat.patch`](../dkms/patches/0004-sysctl-table-sentinel-pre-6.4-compat.patch),
which the build pipeline applies automatically.

If you see this on a customer host running an unmodified meshstor-ms
package, file an issue — the package shouldn't ever ship a tarball
where the patch wasn't applied. See
[maintainer.md](maintainer.md#the-sysctl-sentinel-patch-case-study)
for the diagnostic flow that originally identified this.

## See also

- [install.md](install.md) — how to install
- [compat.md](compat.md) — what's supported, bitmap caveats per kernel
- [performance.md](performance.md) — measured perf, when llbitmap helps
- [architecture.md](architecture.md) — design context (why two subsystems can coexist)
