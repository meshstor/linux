# Reproduce: per-bucket barrier conversion in md/raid10

How to verify on a fresh Linux box that:

1. **Stock `raid10` has the global-barrier bug** — the test reports a
   resync-induced P99 latency penalty for normal I/O (RED).
2. **A kernel built from this branch removes it** — the same test
   reports near-zero penalty (GREEN).

The test itself is `tools/testing/selftests/md/raid10/test_resync_barrier_contention.sh`.
It builds a 4 × 2 GB tmpfs-backed RAID 10, runs a 4 KB random-write
workload with 256 parallel `sync`-engine writers while the array is
idle and again while a throttled `check` resync is active, and compares
median P99 latency across 3 trials. Threshold defaults to 1.10×.

All commands below assume `bash`, `sudo`, ~5 GB free in `/dev/shm`, and
a machine you can reboot.

---

## 0. Prerequisites

Most distros have these already:

```bash
sudo dnf install -y mdadm fio python3 git util-linux       # Fedora/RHEL
# or
sudo apt install -y mdadm fio python3 git util-linux       # Debian/Ubuntu
```

To build a kernel you also need toolchain + kernel headers:

```bash
# Fedora/RHEL
sudo dnf install -y "@Development Tools" bc bison flex elfutils-libelf-devel \
                    openssl-devel ncurses-devel dwarves rpm-build
# Debian/Ubuntu
sudo apt install -y build-essential bc bison flex libelf-dev \
                    libssl-dev libncurses-dev dwarves
```

---

## 1. Grab the branch and the test

```bash
git clone https://github.com/meshstor/linux.git ~/linux-raid10-repro
cd ~/linux-raid10-repro
git fetch origin per-bucket-arrays
git checkout per-bucket-arrays
ls tools/testing/selftests/md/raid10/
```

You should see `lib.sh`, `test_resync_barrier_contention.sh`, and this file.

---

## 2. RED — run on your current (stock) kernel

This expects to **FAIL** on any kernel where `raid10` still has the
single-scalar barrier (every released kernel as of writing).

```bash
cd ~/linux-raid10-repro
chmod +x tools/testing/selftests/md/raid10/*.sh
sudo tools/testing/selftests/md/raid10/test_resync_barrier_contention.sh
echo "exit: $?"
```

Expected output shape:

```
trial 1: idle iops=... p99= 470us  |  resync iops=... p99= 600us  |  p99 ratio=1.28x
trial 2: ...
trial 3: ...
median p99 ratio (during-resync / idle) = 1.3xx
threshold                                = 1.10x
FAIL: p99 ratio 1.3xx >= 1.10x (global-barrier contention observed during resync)
exit: 1
```

If you instead see `PASS`, either:

- your hardware is too lightly loaded for the contention to surface
  (try `RAID10_NJOBS=512 RAID10_TRIALS=5 sudo .../test_resync_barrier_contention.sh`), or
- your kernel already has the per-bucket conversion.

Skip codes:
- exit 4 → some prerequisite missing (root, `/dev/shm` tmpfs, tools)
- exit 1 → test ran and FAILed (this is the expected RED)
- exit 0 → test ran and PASSed

---

## 3. Build & boot a kernel with the fix

`raid10` is normally compiled in, so to test the fix you need a kernel
built from this branch. Two recipes:

### 3a. Quick: build only the raid10 module, install + reload

This works if your distro kernel was configured with
`CONFIG_MD_RAID10=m` (module), not `=y` (built-in). Check first:

```bash
zcat /proc/config.gz 2>/dev/null | grep CONFIG_MD_RAID10= || \
  grep CONFIG_MD_RAID10= /boot/config-$(uname -r)
```

If you see `CONFIG_MD_RAID10=m`, you can rebuild just that module:

```bash
sudo dnf install -y kernel-devel-$(uname -r)            # Fedora/RHEL
# or
sudo apt install -y "linux-headers-$(uname -r)"         # Debian/Ubuntu

cd ~/linux-raid10-repro
KSRC=/lib/modules/$(uname -r)/build
make -C "$KSRC" M=$PWD/drivers/md modules
sudo rmmod raid10            # nothing else can be using it
sudo cp drivers/md/raid10.ko "/lib/modules/$(uname -r)/kernel/drivers/md/raid10.ko"
sudo depmod -a
sudo modprobe raid10
```

(If `rmmod` fails with "module is in use", stop any md arrays first:
`cat /proc/mdstat` then `sudo mdadm --stop /dev/mdN`.)

### 3b. Full: build and boot a custom kernel

If `CONFIG_MD_RAID10=y` (most distro kernels) you have to rebuild the
kernel image:

```bash
cd ~/linux-raid10-repro
# start from your running kernel's config
zcat /proc/config.gz > .config 2>/dev/null || cp /boot/config-$(uname -r) .config
make olddefconfig

# make sure raid10 is at least a module so we can iterate without
# reboots in the future; harmless if it was already =y/=m
scripts/config --module CONFIG_MD_RAID10
make olddefconfig

make -j"$(nproc)"
sudo make modules_install
sudo make install               # creates /boot/vmlinuz-* and updates grub
sudo reboot
```

After reboot, confirm you're on the new kernel:

```bash
uname -r
# pick the kernel you just built from the grub menu if it didn't boot by default
```

### 3c. VM alternative (no host reboot)

Build as in 3b but skip `make install`; boot the built `arch/x86/boot/bzImage`
under QEMU with virtio-blk loop devices, then `scp` the test in. Out
of scope for this doc — search `kdevops` or `virtme-ng` for ready-made
harnesses.

---

## 4. GREEN — re-run the test

Same command, on the rebuilt kernel:

```bash
cd ~/linux-raid10-repro
sudo tools/testing/selftests/md/raid10/test_resync_barrier_contention.sh
echo "exit: $?"
```

Expected output shape:

```
trial 1: idle iops=... p99= 470us  |  resync iops=... p99= 470us  |  p99 ratio=1.00x
trial 2: ...
trial 3: ...
median p99 ratio (during-resync / idle) = 0.9xx-1.0x
threshold                                = 1.10x
PASS: p99 ratio 0.9xx < 1.10x (per-bucket barriers in effect)
exit: 0
```

If you instead see FAIL on the rebuilt kernel:

- confirm the new module is actually loaded:
  `modinfo raid10 | head -3` — `filename:` should point to a path
  matching your build (e.g. under `/lib/modules/<your-new-kernel>/`),
  and `srcversion:` should differ from the one you had before;
- confirm `struct r10conf` in the loaded kernel is per-bucket: with
  `pahole raid10` (from the `dwarves` package) the fields should be
  `atomic_t *nr_pending; atomic_t *nr_waiting; atomic_t *nr_queued;
  atomic_t *barrier;` — not bare `atomic_t nr_pending` plus three `int`.

---

## 5. Tuning the test

| variable                          | default        | what it does |
|-----------------------------------|----------------|--------------|
| `RAID10_P99_RATIO_THRESHOLD`      | `1.10`         | PASS if median ratio is strictly below this |
| `RAID10_TRIALS`                   | `3`            | trial count; bigger = less noise |
| `RAID10_NJOBS`                    | `256`          | parallel `sync` writers; bigger = more contention |
| `RAID10_FIO_SECS`                 | `8`            | seconds per fio run |
| `RAID10_SYNC_KBPS`                | `8192`         | resync throttle in KB/s |
| `RAID10_IMG_DIR`                  | `/dev/shm`     | where to put the 4 × 2 GB loop images |
| `RAID10_LOOP_SIZE`                | `2G`           | loop size; bigger array makes resync stay active longer |
| `MDADM`                           | `mdadm`        | binary to use (set to a patched mdadm for ms variants) |
| `RAID10_DEV_PREFIX`               | `md`           | basename prefix; `ms` for the meshstor-ms variant |
| `RAID10_SYSFS_SUBDIR`             | `md`           | `/sys/block/<dev>/<this>/`; `ms` for meshstor-ms |
| `RAID10_MDSTAT`                   | `/proc/mdstat` | personality file; `/proc/msstat` for meshstor-ms |

Example: be stricter, run longer:

```bash
sudo RAID10_TRIALS=5 RAID10_NJOBS=512 RAID10_P99_RATIO_THRESHOLD=1.05 \
  tools/testing/selftests/md/raid10/test_resync_barrier_contention.sh
```

---

## 6. Cleanup

The test cleans up after itself (loops, files, array). If something
crashes mid-run:

```bash
# stop any md test array
for n in $(seq 240 255); do
  sudo mdadm --stop "/dev/md${n}" 2>/dev/null
done
# detach test loops
losetup -a | awk -F: '/raid10-selftest/{print $1}' | xargs -r sudo losetup -d
# remove backing files
sudo rm -f /dev/shm/raid10-selftest.*.img
```

---

## What the test actually proves

- **RED on master**: with a single scalar `conf->barrier`, every regular
  I/O issued while resync is active falls onto the `wait_barrier()`
  slow path, which takes `write_seqlock_irq(&conf->resync_lock)` — a
  single per-array spinlock — around an `atomic_inc(nr_pending)`. The
  slow path does *not* sleep (the `bio_list` clause in
  `stop_waiting_barrier()` lets bio-submit context through), but the
  spinlock contention is enough to inflate submission P99 latency by
  20–40 % even on a fast CPU with tmpfs backing.

- **GREEN on this branch**: `nr_pending`, `nr_waiting`, `nr_queued`,
  and `barrier` become per-bucket arrays of `atomic_t` keyed by a
  64 MB hash bucket. A random 4 KB write almost always hashes to a
  bucket that resync is not currently working on, and
  `wait_barrier_nolock()` short-circuits via an unlocked
  `atomic_read(&conf->barrier[idx])` — no seqlock acquisition at all.
  The contention disappears.

The test does **not** verify the correctness of `freeze_array`
(commit `f5068df5`); that fix is a property of the slow paths under
`handle_read_error()`, which would need fault injection (e.g. via
`dm-error`/`scsi_debug`) to exercise.
