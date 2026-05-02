#!/usr/bin/env bash
# Perf matrix for meshstor-ms vs kernel-md on baremetal NVMe partitions.
# Measures raid1 + raid10 IOPS at 4k randread/randwrite + llbitmap effect.
#
# Usage: bash ms-perf.sh
# Requires: /dev/nvme0n1p4..p8 partitioned, /tmp/msadm, kernel mdadm, fio.

set -e

KVER=$(uname -r)
DISTRO=$(awk -F'"' '/^PRETTY_NAME/{print $2}' /etc/os-release)
PARTS=(/dev/nvme0n1p4 /dev/nvme0n1p5 /dev/nvme0n1p6 /dev/nvme0n1p7)
P0=${PARTS[0]}; P1=${PARTS[1]}; P2=${PARTS[2]}; P3=${PARTS[3]}
RUN_S=20      # seconds per fio run
RAMP_S=5      # ramp-up
SIZE=8G       # per-job working set

cleanup() {
    sudo /tmp/msadm --stop /dev/ms0 2>/dev/null || true
    sudo mdadm --stop /dev/md0 2>/dev/null || true
    sudo /tmp/msadm --zero-superblock "${PARTS[@]}" 2>/dev/null || true
    sudo mdadm --zero-superblock "${PARTS[@]}" 2>/dev/null || true
    sleep 1
}

# fio invocation; $1 = device, $2 = readwrite mode, $3 = label
fio_run() {
    local dev="$1" rw="$2" label="$3"
    sudo fio --name=$label --filename=$dev --direct=1 --ioengine=libaio \
        --rw=$rw --bs=4k --iodepth=32 --numjobs=4 --runtime=$RUN_S \
        --ramp_time=$RAMP_S --group_reporting --time_based \
        --size=$SIZE --output-format=normal 2>&1 | \
        awk '/IOPS=/ && !done {print; done=1}' | head -1
}

drop_caches() { sudo sync; sudo bash -c 'echo 3 > /proc/sys/vm/drop_caches'; }

echo "============================================================"
echo "Host:       $(hostname)"
echo "Distro:     $DISTRO"
echo "Kernel:     $KVER"
echo "Partitions: ${PARTS[@]}"
echo "============================================================"
echo

cleanup

# ============================================================
# 1. RAID1 — kernel md vs ms (internal bitmap)
# ============================================================
echo "=== 1a. raid1 / kernel md / internal bitmap ==="
sudo mdadm --create /dev/md0 --level=raid1 --raid-devices=2 \
    --bitmap=internal --metadata=1.2 --run --assume-clean $P0 $P1 >/dev/null 2>&1
sleep 2
drop_caches
echo -n "  randread : "; fio_run /dev/md0 randread r1-md-rd
drop_caches
echo -n "  randwrite: "; fio_run /dev/md0 randwrite r1-md-wr
cleanup

echo "=== 1b. raid1 / ms / internal bitmap ==="
sudo /tmp/msadm --create /dev/ms0 --level=raid1 --raid-devices=2 \
    --bitmap=internal --metadata=1.2 --run --assume-clean $P0 $P1 >/dev/null 2>&1
sleep 2
drop_caches
echo -n "  randread : "; fio_run /dev/ms0 randread r1-ms-rd
drop_caches
echo -n "  randwrite: "; fio_run /dev/ms0 randwrite r1-ms-wr
cleanup

echo "=== 1c. raid1 / ms / llbitmap ==="
sudo /tmp/msadm --create /dev/ms0 --level=raid1 --raid-devices=2 \
    --bitmap=lockless --metadata=1.2 --run --assume-clean $P0 $P1 >/dev/null 2>&1
sleep 2
drop_caches
echo -n "  randread : "; fio_run /dev/ms0 randread r1-ll-rd
drop_caches
echo -n "  randwrite: "; fio_run /dev/ms0 randwrite r1-ll-wr
cleanup

# ============================================================
# 2. RAID10 — kernel md vs ms (4 disks, near=2 layout)
# ============================================================
echo "=== 2a. raid10 / kernel md / internal bitmap ==="
sudo mdadm --create /dev/md0 --level=raid10 --raid-devices=4 \
    --bitmap=internal --metadata=1.2 --run --assume-clean $P0 $P1 $P2 $P3 >/dev/null 2>&1
sleep 2
drop_caches
echo -n "  randread : "; fio_run /dev/md0 randread r10-md-rd
drop_caches
echo -n "  randwrite: "; fio_run /dev/md0 randwrite r10-md-wr
cleanup

echo "=== 2b. raid10 / ms / internal bitmap ==="
sudo /tmp/msadm --create /dev/ms0 --level=raid10 --raid-devices=4 \
    --bitmap=internal --metadata=1.2 --run --assume-clean $P0 $P1 $P2 $P3 >/dev/null 2>&1
sleep 2
drop_caches
echo -n "  randread : "; fio_run /dev/ms0 randread r10-ms-rd
drop_caches
echo -n "  randwrite: "; fio_run /dev/ms0 randwrite r10-ms-wr
cleanup

echo "=== 2c. raid10 / ms / llbitmap ==="
sudo /tmp/msadm --create /dev/ms0 --level=raid10 --raid-devices=4 \
    --bitmap=lockless --metadata=1.2 --run --assume-clean $P0 $P1 $P2 $P3 >/dev/null 2>&1
sleep 2
drop_caches
echo -n "  randread : "; fio_run /dev/ms0 randread r10-ll-rd
drop_caches
echo -n "  randwrite: "; fio_run /dev/ms0 randwrite r10-ll-wr
cleanup

# ============================================================
# 3. Single-thread randwrite — bitmap-flush hot path
# ============================================================
echo "=== 3a. raid1 single-thread / kernel md internal ==="
sudo mdadm --create /dev/md0 --level=raid1 --raid-devices=2 \
    --bitmap=internal --metadata=1.2 --run --assume-clean $P0 $P1 >/dev/null 2>&1
sleep 2
drop_caches
sudo fio --name=r1-md-st-wr --filename=/dev/md0 --direct=1 --ioengine=libaio \
    --rw=randwrite --bs=4k --iodepth=1 --numjobs=1 --runtime=$RUN_S \
    --ramp_time=$RAMP_S --group_reporting --time_based --size=$SIZE \
    2>&1 | awk '/IOPS=/ && !done {print "  randwrite (qd=1, n=1): " $0; done=1}' | head -1
cleanup

echo "=== 3b. raid1 single-thread / ms internal ==="
sudo /tmp/msadm --create /dev/ms0 --level=raid1 --raid-devices=2 \
    --bitmap=internal --metadata=1.2 --run --assume-clean $P0 $P1 >/dev/null 2>&1
sleep 2
drop_caches
sudo fio --name=r1-ms-st-wr --filename=/dev/ms0 --direct=1 --ioengine=libaio \
    --rw=randwrite --bs=4k --iodepth=1 --numjobs=1 --runtime=$RUN_S \
    --ramp_time=$RAMP_S --group_reporting --time_based --size=$SIZE \
    2>&1 | awk '/IOPS=/ && !done {print "  randwrite (qd=1, n=1): " $0; done=1}' | head -1
cleanup

echo "=== 3c. raid1 single-thread / ms llbitmap ==="
sudo /tmp/msadm --create /dev/ms0 --level=raid1 --raid-devices=2 \
    --bitmap=lockless --metadata=1.2 --run --assume-clean $P0 $P1 >/dev/null 2>&1
sleep 2
drop_caches
sudo fio --name=r1-ll-st-wr --filename=/dev/ms0 --direct=1 --ioengine=libaio \
    --rw=randwrite --bs=4k --iodepth=1 --numjobs=1 --runtime=$RUN_S \
    --ramp_time=$RAMP_S --group_reporting --time_based --size=$SIZE \
    2>&1 | awk '/IOPS=/ && !done {print "  randwrite (qd=1, n=1): " $0; done=1}' | head -1
cleanup

echo
echo "=== DONE on $(hostname) ($KVER) ==="
