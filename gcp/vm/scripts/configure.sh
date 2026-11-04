#!/bin/bash
# Starts the server with the settings of the deployment, from the JSON that the agent passes (the metadata key
# chroma-config). Run at the first boot and at every terraform apply that changes the settings. The old container stops
# before the new one starts, so one process at a time works on /var/lib/chroma.
set -eu
CONFIG=$1
get() { jq -r ".$1 // empty" "$CONFIG"; }
ENGINE=$(get engine); IMAGE=$(get image); ACCESS=$(get access); HOST=$(get host)
ALLOWED_IPS=$(get allowed_ips); ACME_EMAIL=$(get acme_email); API_KEY_SECRET=$(get api_key_secret)

for i in $(seq 1 180); do
  [ -e /var/lib/chroma-first-boot-done ] && break
  sleep 5
done
[ -e /var/lib/chroma-first-boot-done ] || { echo "the first boot did not finish: see the serial port output of the VM"; exit 1; }
mountpoint -q /var/lib/chroma || { echo "the data disk is not mounted at /var/lib/chroma"; exit 1; }

# Docker starts only once the data disk is mounted. The fstab line has nofail, which does not hold back the services: a
# VM that boots without the disk would otherwise serve an empty database from the boot disk.
mkdir -p /etc/systemd/system/docker.service.d
printf '[Unit]\nRequiresMountsFor=/var/lib/chroma\n' > /etc/systemd/system/docker.service.d/chroma-data.conf
systemctl daemon-reload

mkdir -p /etc/chroma
keys=no
if [ "$ENGINE" = vecturadb ] && [ -n "$API_KEY_SECRET" ]; then
  # The key stays in Secret Manager; the service account of the VM may read only this secret. The credentials file of
  # VecturaDB, in the format of Chroma 0.5, is readable by root only; YAML single quotes keep the key as it is.
  token=$(curl -sf -H Metadata-Flavor:Google http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token | jq -r .access_token)
  API_KEY=$(curl -sf -H "Authorization: Bearer $token" "https://secretmanager.googleapis.com/v1/$API_KEY_SECRET/versions/latest:access" | jq -r .payload.data | base64 -d)
  [ -n "$API_KEY" ] || { echo "the API key could not be read from Secret Manager"; exit 1; }
  quoted=$(printf %s "$API_KEY" | sed "s/'/''/g")
  (umask 077; printf "users:\n  - id: admin\n    tokens:\n      - '%s'\n" "$quoted" > /etc/chroma/credentials.yaml)
  keys=yes
else
  rm -f /etc/chroma/credentials.yaml
fi

# Internal: the server answers on the private address, port 8000. Otherwise only Caddy reaches it, on 127.0.0.1.
if [ "$ACCESS" = internal ]; then publish=8000:8000; else publish=127.0.0.1:8000:8000; fi

docker pull -q "$IMAGE"
old=""
if docker inspect chroma >/dev/null 2>&1; then
  old=$(docker inspect chroma | sed -n 's/^ *"Image": "\(sha256:[0-9a-f]*\)",*$/\1/p' | head -n 1)
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
# The image that this run replaced goes, so that the boot disk does not fill up update after update.
new=$(docker image inspect "$IMAGE" | sed -n 's/^ *"Id": "\(sha256:[0-9a-f]*\)",*$/\1/p' | head -n 1)
if [ -n "$old" ] && [ "$old" != "$new" ]; then docker image rm "$old" >/dev/null 2>&1 || true; fi

if [ "$ACCESS" = internal ]; then
  systemctl disable --now caddy || true
else
  case "$HOST" in *[!0-9.]*) ip=no ;; *) ip=yes ;; esac
  {
    if [ -n "$ACME_EMAIL" ] || [ "$ip" = yes ]; then
      printf '{\n'
      if [ -n "$ACME_EMAIL" ]; then printf '\temail %s\n' "$ACME_EMAIL"; fi
      # Clients send no SNI to an IP address, and the VM sees its private address, not the external IP: without a
      # default name, Caddy finds no certificate and refuses the handshake.
      if [ "$ip" = yes ]; then printf '\tdefault_sni %s\n' "$HOST"; fi
      printf '}\n\n'
    fi
    # Port 80 only answers the HTTP-01 challenge of the certificate, which Caddy handles before this block.
    printf 'http://%s {\n\tabort\n}\n\n' "$HOST"
    printf '%s {\n' "$HOST"
    if [ "$ip" = yes ]; then
      # Let's Encrypt gives certificates for IP addresses only with its short-lived profile, valid for about 6 days:
      # Caddy renews them. Without this block Caddy would use its own local CA for an IP.
      printf '\ttls {\n\t\tissuer acme {\n\t\t\tprofile shortlived\n'
      if [ -n "$ACME_EMAIL" ]; then printf '\t\t\temail %s\n' "$ACME_EMAIL"; fi
      printf '\t\t}\n\t}\n'
    fi
    if [ "$ACCESS" = allowed-ips ]; then
      printf '\t@denied not remote_ip %s\n\tabort @denied\n' "$ALLOWED_IPS"
    fi
    printf '\treverse_proxy 127.0.0.1:8000\n}\n'
  } > /etc/caddy/Caddyfile
  caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile
  systemctl enable caddy
  systemctl reload-or-restart caddy
  # The deployment is complete only once Caddy holds the certificate: right after the reload, HTTPS is not ready yet.
  cert=no
  for i in $(seq 1 90); do
    if ls /var/lib/caddy/.local/share/caddy/certificates/*/"$HOST"/"$HOST".crt >/dev/null 2>&1; then cert=yes; break; fi
    sleep 2
  done
  [ "$cert" = yes ] || { journalctl -u caddy --no-pager | tail -n 20; echo "no HTTPS certificate for $HOST after 180 s"; exit 1; }
fi
docker ps --filter name=chroma --format '{{.Names}} {{.Image}} {{.Status}}'
echo "the server answers"
