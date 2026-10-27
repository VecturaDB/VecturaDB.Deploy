#!/bin/sh
# Run Command of the template, at every deployment: starts the server with the image and the settings of this
# deployment. The old container stops before the new one starts, so one process at a time works on /var/lib/chroma.
# Parameters arrive as environment variables: ENGINE, IMAGE, ACCESS (internal, allowed-ips, public), HOST,
# ALLOWED_IPS (separated by spaces), ACME_EMAIL, DEPLOYED_AT (the time of the deployment, which makes every
# deployment run this script), and API_KEY (protected). POSIX sh, whatever shell runs it.
set -eu
echo "deployment of ${DEPLOYED_AT:-unknown time}"
cloud-init status --wait >/dev/null || true
[ -e /var/lib/chroma-first-boot-done ] || { echo "the first boot did not finish: see /var/log/cloud-init-output.log"; exit 1; }
mountpoint -q /var/lib/chroma || { echo "the data disk is not mounted at /var/lib/chroma"; exit 1; }

# Docker starts only once the data disk is mounted. The fstab line has nofail, which does not hold back the services:
# a VM that boots without the disk would otherwise serve an empty database from the OS disk.
mkdir -p /etc/systemd/system/docker.service.d
printf '[Unit]\nRequiresMountsFor=/var/lib/chroma\n' > /etc/systemd/system/docker.service.d/chroma-data.conf
systemctl daemon-reload

mkdir -p /etc/chroma
keys=no
if [ "$ENGINE" = vecturadb ] && [ -n "${API_KEY:-}" ]; then
  # The credentials file of VecturaDB, in the format of Chroma 0.5. YAML single quotes keep the key as it is.
  quoted=$(printf %s "$API_KEY" | sed "s/'/''/g")
  (umask 077; printf "users:\n  - id: admin\n    tokens:\n      - '%s'\n" "$quoted" > /etc/chroma/credentials.yaml)
  keys=yes
else
  rm -f /etc/chroma/credentials.yaml
fi

# Internal: the server answers on the private address, port 8000. Otherwise only Caddy reaches it, on 127.0.0.1.
if [ "$ACCESS" = internal ]; then publish=8000:8000; else publish=127.0.0.1:8000:8000; fi

docker pull -q "$IMAGE"
if docker inspect chroma >/dev/null 2>&1; then
  docker stop -t 30 chroma
  docker rm chroma
fi
if [ "$keys" = yes ]; then
  docker run -d --name chroma --restart unless-stopped -p "$publish" -v /var/lib/chroma:/data \
    -v /etc/chroma/credentials.yaml:/credentials/credentials.yaml:ro \
    -e CHROMA_SERVER_AUTHN_CREDENTIALS_FILE=/credentials/credentials.yaml "$IMAGE"
else
  docker run -d --name chroma --restart unless-stopped -p "$publish" -v /var/lib/chroma:/data "$IMAGE"
fi
ready=no
for i in $(seq 1 90); do
  if curl -sf -o /dev/null http://127.0.0.1:8000/api/v2/heartbeat; then ready=yes; break; fi
  sleep 2
done
[ "$ready" = yes ] || { docker logs --tail 50 chroma; echo "the server did not answer"; exit 1; }

if [ "$ACCESS" = internal ]; then
  systemctl disable --now caddy || true
else
  {
    if [ -n "${ACME_EMAIL:-}" ]; then printf '{\n\temail %s\n}\n\n' "$ACME_EMAIL"; fi
    # Port 80 only answers the HTTP-01 challenge of the certificate, which Caddy handles before this block.
    printf 'http://%s {\n\tabort\n}\n\n' "$HOST"
    printf '%s {\n' "$HOST"
    if [ "$ACCESS" = allowed-ips ]; then
      printf '\t@denied not remote_ip %s\n\tabort @denied\n' "$ALLOWED_IPS"
    fi
    printf '\treverse_proxy 127.0.0.1:8000\n}\n'
  } > /etc/caddy/Caddyfile
  caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile
  systemctl enable caddy
  systemctl reload-or-restart caddy
  # The deployment ends only once Caddy holds the certificate: right after the reload, HTTPS is not ready yet.
  cert=no
  for i in $(seq 1 90); do
    if ls /var/lib/caddy/.local/share/caddy/certificates/*/"$HOST"/"$HOST".crt >/dev/null 2>&1; then cert=yes; break; fi
    sleep 2
  done
  [ "$cert" = yes ] || { journalctl -u caddy --no-pager | tail -n 20; echo "no HTTPS certificate for $HOST after 180 s"; exit 1; }
fi
docker ps --filter name=chroma --format 'chroma: {{.Image}} {{.Status}}'
caddy version || true
