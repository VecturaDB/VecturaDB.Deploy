#!/bin/bash
# Restore of a snapshot of the data disk, from Cloud Shell or any shell with gcloud, in this folder after terraform
# apply. Usage: ./restore.sh <snapshot name>
# It creates a disk from the snapshot, attaches it to the VM as chroma-restore, asks the agent of the VM to copy its data
# over the data disk (the metadata key chroma-restore), waits for the result, then detaches and deletes the disk. The
# data written after the snapshot is lost: take a snapshot first if you may want it back.
set -eu
SNAPSHOT=$1
VM=$(terraform output -raw vm); ZONE=$(terraform output -raw zone)
PROJECT=$(terraform output -raw project_id)
DISK="$VM-restore-$(date +%s)"
NONCE=$(date +%s)

t0=$(date +%s)
gcloud compute disks create "$DISK" --source-snapshot "$SNAPSHOT" --type pd-balanced --zone "$ZONE" --project "$PROJECT" --quiet
echo "RESTORE disk from the snapshot after $(( $(date +%s) - t0 )) s"
t0=$(date +%s)
gcloud compute instances attach-disk "$VM" --disk "$DISK" --device-name chroma-restore --zone "$ZONE" --project "$PROJECT" --quiet
echo "ATTACH after $(( $(date +%s) - t0 )) s"
t0=$(date +%s)
gcloud compute instances add-metadata "$VM" --metadata "chroma-restore=$NONCE" --zone "$ZONE" --project "$PROJECT" --quiet
result=""
for i in $(seq 1 360); do
  v=$(gcloud compute instances get-guest-attributes "$VM" --zone "$ZONE" --project "$PROJECT" \
    --query-path=chroma/restore --format='value(value)' 2>/dev/null || true)
  case "$v" in "ok $NONCE"* | "failed $NONCE"*) result=$v; break ;; esac
  sleep 5
done
echo "COPY on the VM after $(( $(date +%s) - t0 )) s: ${result:-no answer after 30 minutes}"
t0=$(date +%s)
gcloud compute instances detach-disk "$VM" --disk "$DISK" --zone "$ZONE" --project "$PROJECT" --quiet
gcloud compute disks delete "$DISK" --zone "$ZONE" --project "$PROJECT" --quiet
echo "DETACH and DELETE after $(( $(date +%s) - t0 )) s"
case "$result" in "ok $NONCE"*) exit 0 ;; *) exit 1 ;; esac
