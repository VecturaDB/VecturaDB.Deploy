#!/bin/bash
# Startup script of the VM: Compute Engine runs it at every boot. The first boot mounts the data disk and installs
# Docker, Caddy and jq; every boot installs the agent from the metadata and starts it. The agent configures the server
# from the metadata key chroma-config, see agent.sh.
set -eux
export DEBIAN_FRONTEND=noninteractive
md() { curl -sf -H Metadata-Flavor:Google "http://metadata.google.internal/computeMetadata/v1/instance/attributes/$1"; }

if [ ! -e /var/lib/chroma-first-boot-done ]; then
  # The data disk: formatted once, mounted at /var/lib/chroma by its label.
  disk=/dev/disk/by-id/google-chroma-data
  for i in $(seq 1 90); do
    [ -e "$disk" ] && break
    sleep 2
  done
  [ -e "$disk" ] || { echo "no data disk"; exit 1; }
  blkid "$disk" >/dev/null 2>&1 || mkfs.ext4 -q -L chroma-data "$disk"
  mkdir -p /var/lib/chroma
  grep -q 'LABEL=chroma-data' /etc/fstab || echo 'LABEL=chroma-data /var/lib/chroma ext4 defaults,nofail 0 2' >> /etc/fstab
  mount -a
  mountpoint -q /var/lib/chroma

  # Docker, with bounded logs.
  mkdir -p /etc/docker
  cat > /etc/docker/daemon.json <<'EOF'
{"log-driver": "json-file", "log-opts": {"max-size": "10m", "max-file": "3"}}
EOF
  apt-get update -q
  apt-get install -y -q docker.io curl jq gnupg debian-keyring debian-archive-keyring apt-transport-https
  systemctl enable --now docker

  # Caddy from its official apt repository, which is signed. Ubuntu 24.04 has an older Caddy in universe.
  curl -1sLf https://dl.cloudsmith.io/public/caddy/stable/gpg.key | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
  curl -1sLf https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt > /etc/apt/sources.list.d/caddy-stable.list
  apt-get update -q
  apt-get install -y -q caddy
  systemctl disable --now caddy

  touch /var/lib/chroma-first-boot-done
fi

# The agent and its scripts come from the metadata, so that an update of the template reaches the VM.
mkdir -p /usr/local/lib/chroma-agent
md chroma-agent > /usr/local/lib/chroma-agent/agent.sh
md chroma-configure > /usr/local/lib/chroma-agent/configure.sh
md chroma-restore-script > /usr/local/lib/chroma-agent/restore.sh
chmod 700 /usr/local/lib/chroma-agent/*.sh
cat > /etc/systemd/system/chroma-agent.service <<'EOF'
[Unit]
Description=Configures the Chroma or VecturaDB server from the metadata of the VM
After=network-online.target docker.service
Wants=network-online.target

[Service]
ExecStart=/bin/bash /usr/local/lib/chroma-agent/agent.sh
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable chroma-agent
systemctl restart chroma-agent
