#!/bin/bash
# Run by terraform apply: waits until the agent of the VM reports the configuration with this hash, at most 20 minutes.
# Usage: wait-configured.sh <vm> <zone> <project> <hash>
NAME=$1; ZONE=$2; PROJECT=$3; HASH=$4
for i in $(seq 1 240); do
  v=$(gcloud compute instances get-guest-attributes "$NAME" --zone "$ZONE" --project "$PROJECT" \
    --query-path=chroma/status --format='value(value)' 2>/dev/null)
  case "$v" in
    "ok $HASH") echo "the server answers"; exit 0 ;;
    "failed $HASH"*) echo "the configuration failed: ${v#failed $HASH: }"; exit 1 ;;
  esac
  sleep 5
done
echo "no answer from the VM after 20 minutes: see its serial port output (gcloud compute instances get-serial-port-output $NAME --zone $ZONE)"
exit 1
