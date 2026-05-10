# Perf-test playbook — copy-paste recipe

Step-by-step bash commands to reproduce the per-feature perf comparison
(`baseline + per-bucket-arrays + takeover + latency-ewma + llbitmap-fastpath`)
on a fresh host. Each block is a single command (or a short pipeline) you
can paste one at a time. Comments above each block explain what it does
and why.

Three topology presets are documented at the bottom (raid1, raid10
same-disk, raid10 cross-disk). Pick one based on your hardware.

---

## Phase 1 — One-time host setup (skip if already done)

### 1.1 Required packages

```bash
# Kernel-API helpers + DKMS + the bench tool. kernel-devel must match
# the running kernel (uname -r) — the rename pass needs its UAPI headers.
dnf config-manager --set-enabled crb
dnf install epel-release
dnf clean all

sudo dnf install -y \
    fio fio-engine-libaio libaio \
    dkms git-filter-repo \
    kernel-devel vim tmux
sudo apt install -y fio dkms git-filter-repo nvme-cli jq linux-headers-generic vim tmux
```

### 1.2 Confirm tools

```bash
# All five must be present and the kernel headers must exist.
command -v fio dkms git-filter-repo nvme jq
test -f /lib/modules/$(uname -r)/build/include/uapi/linux/raid/md_p.h \
    && echo OK || echo MISSING_KERNEL_DEVEL
```

### 1.3 Get the three meshstor repos

```bash
# meshstor kernel fork (this repo)
[ -d ~/linux-meshstor ] || git clone git@github.com:meshstor/linux ~/linux-meshstor
```

```bash
# csi-perf-test (the SNIA + workload suites the bench runs)
[ -d ~/csi-perf-test ] || git clone git@github.com:meshstor/csi-perf-test.git ~/csi-perf-test
```

```bash
# mdadm fork (the --subsys=ms aware mdadm; perf-feature-compare wraps
# it as build/msadm at run-time)
[ -d ~/mdadm ] || git clone git@github.com:meshstor/mdadm ~/mdadm
```

```bash
# Build mdadm (one-time per host). Needs make + a C toolchain + libudev
# headers (provided by systemd-devel on RHEL/Rocky 10).
sudo dnf install -y make gcc systemd-devel
sudo apt install -y make gcc libc6-dev build-essential libudev-dev
( cd ~/mdadm && make -j$(nproc) mdadm )
test -x ~/mdadm/mdadm && echo OK || echo "BUILD FAILED"
```

### 1.4 Confirm SSD thermal thresholds (only first time, or after hw change)

```bash
# wctemp = warning composite temp (Kelvin). cctemp = critical.
# COOL_THRESH_K (default 348 K = 75 °C) should be ~10-15 K below wctemp.
sudo nvme id-ctrl /dev/nvme0n1 | grep -iE 'wctemp|cctemp'
```

---

## Phase 2 — Pick a topology and partition layout

### 2.1 Verify partitions

```bash
# You need 2 partitions for raid1, or 4 for raid10. They must be unmounted
# and not in /proc/mdstat. ~25 GiB each is plenty.
lsblk
cat /proc/mdstat
```

If you don't have free partitions of suitable size, create two 25 GiB
test partitions in the disk's trailing free space:

```bash
sudo ~/linux-meshstor/bin/perf-make-test-partitions /dev/nvme0n1
```

The script accepts both 4Kn and 512e drives, requires an existing GPT
label (it prints the `mklabel gpt` command if missing, but never runs it
itself), and is idempotent on re-runs. To clean up afterwards:

```bash
sudo ~/linux-meshstor/bin/perf-make-test-partitions /dev/nvme0n1 --remove
```

### 2.2 Confirm no existing nvmet / nvme-tcp state will collide

```bash
# If something is already listening on nvmet-tcp port 4420 (e.g., a
# production cluster), pick a different --port (e.g., 14420) below.
sudo ss -lntp | grep 4420 || echo "port 4420 free"
```

### 2.3 Confirm hostnqn won't collide with existing nvme-fabrics state

```bash
# If the host already has nvme-tcp connections (production cluster), the
# bench's nvme connect would clash on hostid/hostnqn. The bench script
# handles this since 2026-05-05 (uses a per-run hostnqn + UUID hostid)
# but verify there are no leftover stale connections.
sudo nvme list-subsys
```

---

## Phase 3 — Run the comparison

Pick the topology block matching your hardware.

### 3.A — raid1 (2 partitions, single disk)

```bash
# Backward-compat positional form. Replace pX with your free partitions.
sudo ~/linux-meshstor/bin/perf-compare \
    /dev/nvme0n1p4 /dev/nvme0n1p5 \
    | tee /tmp/perf-run.log
```

### 3.B — raid10 cross-disk (4 partitions, two disks; each disk has 1 local + 1 tcp)

```bash
sudo ~/linux-meshstor/bin/perf-compare \
    --level=raid10 --port=14420 \
    --local=/dev/nvme0n1p4 --local=/dev/nvme1n1p1 \
    --remote=/dev/nvme1n1p2 --remote=/dev/nvme0n1p5 \
    | tee /tmp/perf-run.log
```

### 3.C — Run only a subset of variants

Append the variant names (any of `baseline per-bucket-arrays takeover
latency-ewma llbitmap-fastpath`) at the end of any of the above:

```bash
sudo ~/linux-meshstor/bin/perf-compare \
    --level=raid10 --port=14420 \
    --local=/dev/nvme0n1p4 --local=/dev/nvme1n1p1 \
    --remote=/dev/nvme1n1p2 --remote=/dev/nvme0n1p5 \
    baseline latency-ewma \
    | tee /tmp/perf-run.log
```

Wall-clock estimate per full run:

| Variants | Suites | Estimate |
|---|---|---|
| 5 | 5 (default: 4 SNIA + ewma-asymmetric-read) | ~80–95 min (cool-down may add more) |
| 1 | 5 | ~16–22 min |
| 5 | 1 (single suite via `SUITES=name`) | ~30 min |

Tuning the thermal gate (default: wait between variants until max sensor
on every leg's parent NVMe drops to ≤ 348 K = 75 °C; devices to monitor
are derived automatically from --local + --remote):

```bash
# Looser gate (e.g., 80 °C — closer to wctemp; faster but may throttle).
sudo ~/linux-meshstor/bin/perf-compare \
    --cool-thresh-k=353 ...
# Disable cooldown entirely (back-to-back, watch your wctemp):
sudo ~/linux-meshstor/bin/perf-compare \
    --cool-thresh-k=0 ...
```

---

## Phase 4 — Watch progress + temperature

In a second terminal:

```bash
# Live event stream from the orchestrator log.
tail -f /tmp/perf-run.log | grep -E '===|WARN|ERROR|all done|FAIL|done:|suite snia.*ok|suite: snia|wait_cool|summary:|msraid'
```

```bash
# One-shot temperature snapshot (max of composite + all sensors, in Kelvin).
sudo nvme smart-log /dev/nvme0n1 -o json | \
    jq -r '[.temperature, .temperature_sensor_1, .temperature_sensor_2,
            (.temperature_sensor_3 // 0), (.temperature_sensor_4 // 0)] | max'
```

```bash
# Continuous temperature watch (every 10 s).
watch -n 10 'sudo nvme smart-log /dev/nvme0n1 -o json | jq -r "[.temperature, .temperature_sensor_1, .temperature_sensor_2, (.temperature_sensor_3 // 0), (.temperature_sensor_4 // 0)] | max" | xargs -I{} echo "max sensor {} K = $((( {} - 273)))°C"'
```

---

## Phase 5 — Build the comparison table

```bash
# OUT_BASE is the directory perf-feature-compare wrote to. With the
# default DATE_TAG it's results/perf-<UTC date>/.
OUT_BASE="$HOME/linux-meshstor/results/perf-$(date -u +%F)"
~/linux-meshstor/bin/perf-extract-table "$OUT_BASE"
```

The helper auto-discovers variants and suites and emits a markdown table
with IOPS + p99 latency for every (variant × suite) pair. It tolerates
fio output that has leading non-JSON lines (which `perf-feature-compare`'s
own parser does NOT — known bug on hosts with `nvme_core.multipath=Y`
where the bench's `drop_caches` plumbing emits warnings into `run.log`).

To redirect to a file:

```bash
~/linux-meshstor/bin/perf-extract-table "$OUT_BASE" \
    > "$OUT_BASE/TABLE.md"
```

---

## Phase 6 — Cleanup verification

```bash
# After the orchestrator's EXIT trap restores state:
#  - the original system meshstor-ms package is reinstalled (or absent
#    if none was present at start)
#  - all per-variant DKMS pkgs are removed
#  - ms_mod / raid1_ms / raid10_ms are loaded from the system pkg
#    (or absent if no system pkg)
#  - no leftover /dev/ms* devices, no leftover nvmet subsystems for
#    `msbench-*`
sudo dkms status | grep meshstor
lsmod | grep -E '^(ms_mod|raid.*_ms) '
ls /dev/ms* 2>/dev/null || echo "no /dev/ms* (clean)"
ls /sys/kernel/config/nvmet/subsystems/ | grep msbench || echo "no msbench (clean)"
```

```bash
# If something IS leftover (rare, only after a hard kill mid-cycle):
sudo nvme list-subsys | grep msbench
# Then disconnect:
sudo nvme disconnect -n <leftover-nqn>
# Tear down nvmet config:
sudo bash -c 'for s in /sys/kernel/config/nvmet/subsystems/nqn.*msbench-*; do [ -e "$s" ] && rmdir "$s/namespaces"/* "$s" 2>/dev/null; done'
sudo bash -c 'for p in /sys/kernel/config/nvmet/ports/*; do [ -e "$p" ] && rm -f "$p/subsystems"/* && rmdir "$p" 2>/dev/null; done'
```

---

## Troubleshooting (issues encountered while writing this playbook)

### `build-tarball failed` after patch 0004

The compat patch `0004-sysctl-table-sentinel-pre-6.4-compat.patch` may
fail on newer torvalds upstreams whose `md.c` sysctl table layout
shifted. The patch was regenerated 2026-05-05 with minimal context that
applies to both old and new upstream. If you see it failing again on
some future upstream:

```bash
# See what the patch expects vs what's in the rebuilt tree
diff -u ~/linux-meshstor/dkms/patches/0004-*.patch <(echo)
sed -n '316,340p' build/linux-meshstor-rebuilt/drivers/md/md.c
```

### `nvme connect: invalid arguments/configuration`

Host already has nvme-fabrics state (production cluster). The bench
script generates a unique hostnqn + hostid per run since 2026-05-05;
verify with:

```bash
grep hostnqn ~/linux-meshstor/bin/perf-bench-tcp
# Should show "msbench-host-..." string
```

### `port already bound: 127.0.0.1:4420`

Use a different port:

```bash
# Append --port=14420 (or any free port) to the perf-feature-compare
# command line. See Phase 3.C for an example.
```

### `rebuild-main failed: $OUTPUT_DIR exists but is not a previous rebuild-main output`

A prior rebuild-main died mid-cycle and didn't write its sentinel.
Clean it manually:

```bash
sudo rm -rf build/linux-meshstor-rebuilt
```

### Suite output shows `iops=- p99_us=-` in SUMMARY.md but raw run.log has data

`perf-feature-compare`'s built-in `extract_iops_json` has a known bug
where it doesn't strip leading non-JSON lines from `run.log`. Use
`bin/perf-extract-table` instead — it handles that case.

### `modprobe: ERROR: could not insert 'raid10_ms': Invalid argument`

The previous variant's `rmmod` failed silently and left its module
loaded; the next variant's `modprobe` rejects its build because
srcversions don't match. Force-remove and retry:

```bash
sudo modprobe -r raid1_ms raid10_ms ms_mod
# If still loaded, find what's holding refcount:
lsmod | head
ls /dev/ms*
# Stop any leftover ms array:
sudo build/msadm --stop /dev/ms0
```

---

## Recipe summary (the "happy path" command sequence)

```bash
# One-time setup (Phase 1):
sudo dnf install -y fio fio-engine-libaio libaio dkms git-filter-repo \
    "kernel-devel-$(uname -r)" make gcc systemd-devel
[ -d ~/linux-meshstor ] || git clone git@github.com:meshstor/linux ~/linux-meshstor
[ -d ~/csi-perf-test ]  || git clone git@github.com:meshstor/csi-perf-test.git ~/csi-perf-test
[ -d ~/mdadm ]          || git clone git@github.com:meshstor/mdadm ~/mdadm
[ -x ~/mdadm/mdadm ]    || ( cd ~/mdadm && make -j$(nproc) mdadm )

# Per-run (Phase 3, raid10 cross-disk example):
sudo ~/linux-meshstor/bin/perf-compare \
    --level=raid10 --port=14420 \
    --local=/dev/nvme0n1p4 --local=/dev/nvme1n1p1 \
    --remote=/dev/nvme1n1p2 --remote=/dev/nvme0n1p5 \
    | tee /tmp/perf-run.log

# Results table (Phase 5):
OUT_BASE="$HOME/linux-meshstor/results/perf-$(date -u +%F)"
~/linux-meshstor/bin/perf-extract-table "$OUT_BASE"
```
