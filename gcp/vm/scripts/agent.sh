#!/bin/bash
# Agent of the VM, run by systemd. It waits for changes of the metadata and:
# - runs configure.sh when the key chroma-config changes: at the first boot, and at every terraform apply that changes the
#   server, its image, the key or the access;
# - runs restore.sh when the key chroma-restore changes, see restore.sh in the template folder.
# The outcome goes to the guest attributes chroma/status and chroma/restore, which terraform apply and restore.sh read.
set -u
BASE=http://metadata.google.internal/computeMetadata/v1/instance
STATE=/var/lib/chroma-agent
mkdir -p "$STATE"
put() { curl -sf -X PUT -H Metadata-Flavor:Google --data "$2" "$BASE/guest-attributes/chroma/$1" >/dev/null || true; }

etag=""
while true; do
  # The first request answers at once; the next ones wait until a key changes, at most 5 minutes.
  query="recursive=true"
  [ -n "$etag" ] && query="$query&wait_for_change=true&timeout_sec=300&last_etag=$etag"
  if ! curl -sf -D "$STATE/headers" -H Metadata-Flavor:Google "$BASE/attributes/?$query" -o "$STATE/attributes.json"; then
    sleep 5
    continue
  fi
  etag=$(tr -d '\r' < "$STATE/headers" | sed -n 's/^[Ee][Tt][Aa][Gg]: *//p')

  config=$(jq -r '."chroma-config" // empty' "$STATE/attributes.json")
  hash=$(printf %s "$config" | sha256sum | cut -c1-16)
  if [ -n "$config" ] && [ "$hash" != "$(cat "$STATE/config-hash" 2>/dev/null)" ]; then
    put status "running $hash"
    if printf %s "$config" > "$STATE/config.json" && bash /usr/local/lib/chroma-agent/configure.sh "$STATE/config.json" > "$STATE/configure.log" 2>&1; then
      printf %s "$hash" > "$STATE/config-hash"
      put status "ok $hash"
    else
      put status "failed $hash: $(tail -n 3 "$STATE/configure.log" | tr '\n' ' ' | cut -c1-400)"
    fi
  fi

  restore=$(jq -r '."chroma-restore" // empty' "$STATE/attributes.json")
  if [ -n "$restore" ] && [ "$restore" != "$(cat "$STATE/restore-done" 2>/dev/null)" ]; then
    put restore "running $restore"
    if bash /usr/local/lib/chroma-agent/restore.sh > "$STATE/restore.log" 2>&1; then
      put restore "ok $restore: $(tail -n 1 "$STATE/restore.log" | cut -c1-300)"
    else
      put restore "failed $restore: $(tail -n 3 "$STATE/restore.log" | tr '\n' ' ' | cut -c1-400)"
    fi
    printf %s "$restore" > "$STATE/restore-done"
  fi
done
