#!/bin/bash
# First boot of the VM: the data disk, Docker and Caddy. The server itself is set up by configure.sh, which the
# template runs at every deployment.
set -eux
export DEBIAN_FRONTEND=noninteractive

# The data disk at LUN 0: formatted once, mounted at /var/lib/chroma.
disk=""
for i in $(seq 1 90); do
  for d in /dev/disk/azure/data/by-lun/0 /dev/disk/azure/scsi1/lun0; do
    if [ -e "$d" ]; then disk=$d; break 2; fi
  done
  sleep 2
done
[ -n "$disk" ] || { echo "no data disk at LUN 0"; exit 1; }
blkid "$disk" >/dev/null 2>&1 || mkfs.ext4 -q -L chroma-data "$disk"
mkdir -p /var/lib/chroma
grep -q 'LABEL=chroma-data' /etc/fstab || echo 'LABEL=chroma-data /var/lib/chroma ext4 defaults,nofail,discard 0 2' >> /etc/fstab
mount -a
mountpoint -q /var/lib/chroma

# Docker, with bounded logs.
mkdir -p /etc/docker
cat > /etc/docker/daemon.json <<'EOF'
{"log-driver": "json-file", "log-opts": {"max-size": "10m", "max-file": "3"}}
EOF
apt-get update -q
apt-get install -y -q docker.io curl gnupg debian-keyring debian-archive-keyring apt-transport-https
systemctl enable --now docker

# Caddy from its official apt repository, which is signed. Ubuntu 24.04 has an older Caddy in universe.
curl -1sLf https://dl.cloudsmith.io/public/caddy/stable/gpg.key | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
curl -1sLf https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt > /etc/apt/sources.list.d/caddy-stable.list
apt-get update -q
apt-get install -y -q caddy
systemctl disable --now caddy

touch /var/lib/chroma-first-boot-done
