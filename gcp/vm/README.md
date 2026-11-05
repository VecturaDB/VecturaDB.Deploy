# Chroma or VecturaDB on one Google Cloud VM

> **Disclaimer.** This template and its scripts are provided as is, without warranty of any kind, as stated in the Apache License 2.0. The numbers below are what we measured on 4 and 5 November 2026 in europe-west1: your region, sizes, data and versions may behave differently. You are responsible for your data: back it up, and test a restore on a copy before you rely on it. Not sure about your case? Open an issue in this repository and we will take a look on a best-effort basis.

The template runs one server in a Google Cloud project of yours, with its data on a disk of its own:

- **Chroma 1.5.9** (`ghcr.io/chroma-core/chroma:1.5.9`, the same image as `chromadb/chroma` on Docker Hub), or
- **VecturaDB 1.0.0-preview.7** (`ghcr.io/vecturadb/vecturadb:1.0.0-preview.7`), built from Chroma, with sparse vectors, BM25, the Search API, collection fork and API keys.

Both servers keep the Chroma API, so the Chroma clients connect with the `url` output.

## What it creates

| Resource | Notes |
|---|---|
| Compute Engine VM, Ubuntu 24.04 | Docker runs the server; Caddy serves HTTPS in front of it |
| Data disk, pd-balanced | Mounted at `/var/lib/chroma`; 16 GB by default |
| VPC, subnet and firewall rules | 10.42.0.0/24; the rules open only what the access mode needs |
| Static external IP address | The address for HTTPS, and the way out to the package and image registries, also with internal access |
| Service account of the VM | No role in the project; it may read only the secret of the API key |
| Snapshot schedule | Only with backups on: snapshots of the data disk |
| Secret Manager secret | Only VecturaDB with an API key |

The project needs the Compute Engine and IAM APIs, Secret Manager with an API key, and Cloud Storage for the bucket of the state: the guides turn them on with `gcloud services enable`.

Files:

- `main.tf`, `variables.tf`, `outputs.tf`, `versions.tf`, `backend.tf`: the template.
- `scripts/`: the first boot of the VM, its agent, the configuration and the restore, passed to the VM in its metadata.
- `chroma.tfvars`, `vecturadb.tfvars`: the settings that the two guides start from.
- `tutorial-chroma.md`, `tutorial-vecturadb.md`: the guides of Cloud Shell.
- `restore.sh`: the restore of a snapshot, run from Cloud Shell.

## Deploy

Google Cloud has no form that creates a deployment from a link, like the buttons of Azure and AWS. The button opens Cloud Shell, the terminal of the Google Cloud console, with this repository and a guide on the side that runs Terraform step by step:

[![Open in Cloud Shell](https://gstatic.com/cloudssh/images/open-btn.svg)](https://shell.cloud.google.com/cloudshell/editor?cloudshell_git_repo=https://github.com/VecturaDB/VecturaDB.Deploy&cloudshell_git_branch=gcp-v1.0.1&cloudshell_workspace=gcp/vm&cloudshell_tutorial=tutorial-chroma.md)

The same with VecturaDB as the server, and the step of the API key:

[![Open in Cloud Shell](https://gstatic.com/cloudssh/images/open-btn.svg)](https://shell.cloud.google.com/cloudshell/editor?cloudshell_git_repo=https://github.com/VecturaDB/VecturaDB.Deploy&cloudshell_git_branch=gcp-v1.0.1&cloudshell_workspace=gcp/vm&cloudshell_tutorial=tutorial-vecturadb.md)

1. Google asks to confirm the clone of the repository. Without "Trust repo", Cloud Shell is temporary: its files are deleted at the end of the session, and it has no credentials until the guide signs you in. If Google asks to authorize Cloud Shell when it opens, it is not needed: click outside it to close it, the guide signs you in. In a temporary Cloud Shell `gcloud auth login` first says that you are already authenticated: answer `Y`.
2. The guide installs Terraform: Cloud Shell has none.
3. It creates a Cloud Storage bucket for the state of Terraform, `<project id>-chroma-tfstate`, in europe-west1, with versioning and without public access. The settings file goes to the bucket too, next to the state.
4. You give the IP address of your computer, and with VecturaDB the API key, then `terraform apply` creates everything.

To change a setting or delete the deployment later, open the guide again: it gets the state and the settings back from the bucket.

With Terraform 1.11 or later on your computer, in a clone of this repository:

```sh
cd gcp/vm
gcloud services enable compute.googleapis.com iam.googleapis.com secretmanager.googleapis.com storage.googleapis.com
gcloud storage buckets create gs://<bucket> --location=europe-west1 --uniform-bucket-level-access --public-access-prevention
terraform init -backend-config=bucket=<bucket> -backend-config=prefix=chroma
export TF_VAR_project_id=<project id>
terraform apply -parallelism=2 -var-file=chroma.tfvars -var 'allowed_ip_ranges=["203.0.113.10/32"]'
```

For VecturaDB with an API key, use `vecturadb.tfvars` and `export TF_VAR_api_key=<your key>` first. To keep the state in a local file instead of a bucket, delete `backend.tf` before `terraform init`. The `wait` of the apply uses `gcloud`, which must be signed in to the project.

The commands run Terraform with `-parallelism=2`: in our tests from Cloud Shell, with the default of 10 parallel operations 5 plans out of 11 failed with a refused connection to the Google APIs, and with 2 none out of 11.

`terraform apply` ends only when the server answers, over HTTPS with its certificate. In our tests of 5 November a deployment from zero took 376-626 seconds: most of it is the first boot of the VM, which installs Docker and Caddy from the package repositories, so its time depends on them. In the test of 626 seconds the first boot took 6 minutes 29 seconds, and the list of the Ubuntu packages alone 2 minutes 6 seconds. Installing Terraform in Cloud Shell took about 40 seconds.

## Sizes and cost

The sizes of the template, with the list prices of europe-west1 in USD from the catalog of Google Cloud, for 730 hours a month, on 4 November 2026:

| Size | CPU, memory | VM | Boot disk 10 GB | Data disk 16 GB | External IP | Total a month |
|---|---|---|---|---|---|---|
| e2-micro (default) | 2 shared vCPU, 1 GB | 6.73 | 1.00 | 1.60 | 3.65 | 12.98 |
| e2-small | 2 shared vCPU, 2 GB | 13.45 | 1.00 | 1.60 | 3.65 | 19.70 |
| e2-medium | 2 shared vCPU, 4 GB | 26.91 | 1.00 | 1.60 | 3.65 | 33.16 |

- We tested only e2-micro.
- The e2 shared-core types run at a fraction of a vCPU, and burst above it for short periods: e2-micro at 0.25 of a vCPU, e2-small at 0.5, e2-medium at 1. A server that is busy all the time needs a larger size.
- With an API key, Secret Manager bills 0.06 USD a month for each active version of a secret beyond the first 6 of the billing account, and 0.03 USD per 10,000 accesses beyond the first 10,000. The VM reads the key at every configuration.
- Snapshots: 0.05 USD per GB a month, for the data they hold.
- Not in the table: outbound traffic, and the bucket of the state, a few KB.

## Access, ports and HTTPS

| Access | What is open | Address |
|---|---|---|
| `allowed-ips` | 443 from the IP ranges you give; 80 from anywhere, for the certificate only | `https://<external IP>`, or your domain |
| `public` | 443 and 80 from anywhere; VecturaDB with an API key only | the same |
| `internal` | nothing from the internet; port 8000 inside the VPC | `http://<private IP>:8000` |

- Caddy, from its own signed apt repository, gets a Let's Encrypt certificate and forwards to the server on 127.0.0.1:8000.
- Without `domain_name`, the certificate is for the external IP itself: Let's Encrypt issues those only with its short-lived profile, and Caddy renews them. Clients send no server name (SNI) to an IP address: the template gives Caddy the external IP as the default name, so that it finds the certificate.
- With `domain_name` and a DNS A record to the external IP (the `public_ip` output), the certificate is for your domain. The IP stays the same across updates: deploy first without the domain, create the record, then apply again with `domain_name`.
- Port 80 answers only the challenge of the certificate. With `allowed-ips`, Caddy also closes the requests from other addresses on 443.
- There is no SSH: no firewall rule opens port 22. The agent of the VM reads its settings from the metadata of the VM, and reports the outcome in the guest attributes, which `terraform apply` waits for. If the configuration fails, the apply fails with the reason.
- Chroma 1.5.9 has no API keys: that is why `public` needs VecturaDB with `api_key`. The key goes to Secret Manager as a write-only value: it is not in the state of Terraform, nor in the settings file. The VM writes it to a file readable by root only. Every request needs it in the `x-chroma-token` header.

In our tests the Python client (chromadb 1.5.9) worked over HTTPS on the external IP with both servers, and VecturaDB refused the requests without the key.

## Backups and restore

With `backup = "snapshots"` (the default), a snapshot schedule of Compute Engine takes snapshots of the data disk, every 24 hours by default (`backup_every_hours`: 4, 6, 8, 12 or 24), and keeps them 7 days (`backup_retention_days`), in the region of the deployment. They have the label `chroma-backup` with the name of the deployment. **The snapshots are not part of the deployment**: `terraform destroy` leaves them, see [Delete everything](#delete-everything).

The snapshots are taken while the server runs, so a restored disk is like a disk after a power cut: the restore checks its file system before it uses it.

To list the snapshots:

```sh
gcloud compute snapshots list --filter="labels.chroma-backup=chroma"
```

To restore one, in this folder after `terraform init` with the same bucket and folder:

```sh
./restore.sh <snapshot name>
```

`restore.sh` creates a disk from the snapshot, attaches it to the VM, asks the agent of the VM to copy its data, waits for the answer, then detaches and deletes the disk. On the VM the restore stops the server, replaces the data in `/var/lib/chroma` with the data of the snapshot, and starts the server again. The data disk stays the same, so the snapshots go on. **The data written after the snapshot is lost**: take a snapshot first if you may want it back (`gcloud compute disks snapshot chroma-data --zone europe-west1-b`).

In our tests:

| Step | Time |
|---|---|
| Snapshot by hand | 32-48 s |
| Disk from the snapshot | 23-26 s |
| Attach | 6-20 s |
| Copy on the VM, until the server answers | 7-9 s |
| Detach and delete | 8-9 s |

With Chroma 1.5.9 and with VecturaDB 1.0.0-preview.7, after each restore the server held all the collections of the snapshot, also the one written right before it.

## Updates and restarts

- To change the server, its image, the access or the key, apply again with the new settings. When they change, the agent of the VM runs the configuration again: it pulls the image, stops the old container (up to 30 seconds), starts the new one and waits for it. The server is down during the switch. An apply that changes none of them does not restart the server.
- The data stays on the data disk. In our tests a switch from Chroma 1.5.9 to VecturaDB with an API key took 33 seconds, and VecturaDB read the collections written by Chroma; a new key took 25 seconds, and afterwards the client could no longer connect with the old key.
- The image of the operating system is the latest Ubuntu 24.04 at the creation. An apply never replaces the VM, so it never moves the data disk. Ubuntu installs its security updates by itself (unattended-upgrades), Docker included.
- A change of `machine_type` stops and starts the same VM.
- Docker starts only once the data disk is mounted. A VM that boots without its data disk serves nothing, rather than an empty database.

## Delete everything

`terraform destroy` deletes the VM, the data disk, the network, the IP address, the service account and the secret. The snapshots stay: delete them after the VM, so that no new snapshot comes after the cleanup. Then delete the state and the settings in the bucket:

```sh
terraform destroy -parallelism=2 -var-file=chroma.tfvars && for s in $(gcloud compute snapshots list --filter="labels.chroma-backup=chroma" --format="value(name)" --verbosity=error); do gcloud compute snapshots delete $s --quiet; done && gcloud storage rm --recursive --all-versions gs://<bucket>/chroma
```

In our tests `terraform destroy` took 109-141 seconds from a computer, also without the API key, and 2 minutes 28 seconds in Cloud Shell with its confirmation; afterwards nothing of the deployment was left in the project.

## Limits

- One VM and one disk: no high availability. While the VM restarts or an update switches the container, the server does not answer.
- The snapshots are in the same region.
- The certificate of an IP address is valid for about 6 days: Caddy renews it while the VM runs.
- Caddy comes from its own repository, which unattended-upgrades leaves out.
- The guides use europe-west1 for the bucket of the state; the deployment can be in any region with e2 types.

## License and trademarks

Apache License 2.0, as is, without warranty of any kind.

VecturaDB is an independent fork of Chroma, under the Apache License 2.0. The original code is copyright Chroma Inc. and its contributors.

Not affiliated with, endorsed by or sponsored by Chroma Inc. CHROMA is a registered trademark of Chroma Inc., used here only to describe compatibility.
