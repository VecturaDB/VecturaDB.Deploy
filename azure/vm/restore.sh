#!/bin/sh
# Restore of a backup. The backup vault restores a recovery point to a new disk, the disk goes to the VM at LUN 1, and
# this script, run with Run Command, copies its data over /var/lib/chroma and starts the server again. The data disk
# stays the same, so the template and the backups keep working on it. Afterwards detach and delete the restored disk.
# The current data is replaced: take an on-demand backup first to keep it. POSIX sh, whatever shell runs it.
set -eu
fail() { echo "$1"; exit 1; }

src=""
for d in /dev/disk/azure/data/by-lun/1 /dev/disk/azure/scsi1/lun1; do
  if [ -e "$d" ]; then src=$(readlink -f "$d"); break; fi
done
[ -n "$src" ] || fail "no disk at LUN 1: attach the restored disk there first"
mountpoint -q /var/lib/chroma || fail "the data disk is not mounted at /var/lib/chroma"
if findmnt -rn -S "$src" >/dev/null; then fail "the disk at LUN 1 is mounted: it must be the restored disk, not in use"; fi

# The restored disk is a copy of the data disk, label included: a label of its own keeps the fstab line on the data disk.
e2fsck -p "$src" || [ $? -le 1 ] || fail "the file system of the disk at LUN 1 has errors"
tune2fs -L chroma-restore "$src" >/dev/null
mkdir -p /mnt/chroma-restore
mount -o ro "$src" /mnt/chroma-restore
if [ ! -e /mnt/chroma-restore/chroma.sqlite3 ]; then
  umount /mnt/chroma-restore
  fail "the disk at LUN 1 holds no chroma.sqlite3: not a data disk of this template"
fi

t0=$(date +%s)
docker stop -t 30 chroma >/dev/null
find /var/lib/chroma -mindepth 1 -maxdepth 1 ! -name lost+found -exec rm -rf {} +
cp -a /mnt/chroma-restore/. /var/lib/chroma/
umount /mnt/chroma-restore
t1=$(date +%s)
docker start chroma >/dev/null
ready=no
for i in $(seq 1 90); do
  if curl -sf -o /dev/null http://127.0.0.1:8000/api/v2/heartbeat; then ready=yes; break; fi
  sleep 2
done
[ "$ready" = yes ] || { docker logs --tail 50 chroma; fail "the server did not answer after the restore"; }
echo "restored $(du -sh /var/lib/chroma | cut -f1) in $((t1 - t0)) s, server ready $(( $(date +%s) - t1 )) s later: detach the disk at LUN 1 now"
