#!/bin/bash
# Run by the agent on the VM when the metadata key chroma-restore changes: copies the data of the disk attached with the
# device name chroma-restore (a disk created from a snapshot) over /var/lib/chroma, and starts the server again. The
# data disk stays the same, so the deployment and the snapshots keep working on it. The current data is replaced: take
# a snapshot first to keep it. See restore.sh in the template folder, which runs the whole restore from Cloud Shell.
set -eu
fail() { echo "$1"; exit 1; }

disk=/dev/disk/by-id/google-chroma-restore
src=""
for i in $(seq 1 30); do
  if [ -e "$disk" ]; then src=$(readlink -f "$disk"); break; fi
  sleep 2
done
[ -n "$src" ] || fail "no disk attached with the device name chroma-restore"
mountpoint -q /var/lib/chroma || fail "the data disk is not mounted at /var/lib/chroma"
if findmnt -rn -S "$src" >/dev/null; then fail "the disk chroma-restore is mounted: it must be the restored disk, not one in use"; fi

# The restored disk is a copy of the data disk, label included: a label of its own keeps the fstab line on the data disk.
e2fsck -p "$src" || [ $? -le 1 ] || fail "the file system of the restored disk has errors"
tune2fs -L chroma-restore "$src" >/dev/null
mkdir -p /mnt/chroma-restore
mount -o ro "$src" /mnt/chroma-restore
if [ ! -e /mnt/chroma-restore/chroma.sqlite3 ]; then
  umount /mnt/chroma-restore
  fail "the restored disk holds no chroma.sqlite3: not a data disk of this template"
fi

t0=$(date +%s)
docker stop -t 30 chroma >/dev/null
find /var/lib/chroma -mindepth 1 -maxdepth 1 ! -name lost+found -exec rm -rf {} +
cp -a /mnt/chroma-restore/. /var/lib/chroma/
# Write the copy to the disk before the server starts: Linux would do it up to about 30 seconds later, and a
# snapshot or a power cut in that time could keep empty files.
sync
umount /mnt/chroma-restore
t1=$(date +%s)
docker start chroma >/dev/null
ready=no
for i in $(seq 1 90); do
  if curl -sf -o /dev/null http://127.0.0.1:8000/api/v2/heartbeat; then ready=yes; break; fi
  sleep 2
done
[ "$ready" = yes ] || { docker logs --tail 50 chroma; fail "the server did not answer after the restore"; }
echo "restored $(du -sh /var/lib/chroma | cut -f1) in $((t1 - t0)) s, server ready $(( $(date +%s) - t1 )) s later"
