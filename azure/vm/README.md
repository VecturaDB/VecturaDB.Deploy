# Chroma or VecturaDB on one Azure VM

> **Disclaimer.** This template and its scripts are provided as is, without warranty of any kind, as stated in the Apache License 2.0. The numbers below are what we measured on 25, 26 and 27 October 2026 in westeurope: your region, sizes, data and versions may behave differently. You are responsible for your data: back it up, and test a restore on a copy before you rely on it. Not sure about your case? Open an issue in this repository and we will take a look on a best-effort basis.

The template runs one server in your own Azure subscription, with its data on a managed disk:

- **Chroma 1.5.9** (`ghcr.io/chroma-core/chroma:1.5.9`, the same image as `chromadb/chroma` on Docker Hub), or
- **VecturaDB 1.0.0-preview.3.post1** (`ghcr.io/vecturadb/vecturadb:1.0.0-preview.3.post1`), built from Chroma, with sparse vectors, BM25, the Search API, collection fork and API keys.

Both servers keep the Chroma API, so the Chroma clients connect with the URL of the deployment.

## What it creates

| Resource | Notes |
|---|---|
| Ubuntu 24.04 VM | Docker runs the server; Caddy serves HTTPS in front of it |
| Data disk, Standard SSD | Mounted at `/var/lib/chroma`; 16 GiB by default |
| Network security group | Opens only what the access mode needs |
| Virtual network and NIC | 10.42.0.0/16 |
| Public IP, Standard | Only with HTTPS access (allowed IPs or public) |
| Backup vault | Only with backups on: Azure Disk Backup of the data disk |

Files:

- `main.bicep`: the template; `azuredeploy.json` is the same template compiled to ARM JSON;
- `createUiDefinition.json`: the form of the Azure portal; `createUiDefinition.vecturadb.json` is the same form with VecturaDB already chosen;
- `cloud-init.sh`: the first boot (data disk, Docker, Caddy);
- `configure.sh`: run at every deployment, it starts the server with the settings of that deployment;
- `restore.sh`: restores a backup (see below).

## Deploy

[![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2FVecturaDB%2FVecturaDB.Deploy%2Fazure-v1.2.0%2Fazure%2Fvm%2Fazuredeploy.json/createUIDefinitionUri/https%3A%2F%2Fraw.githubusercontent.com%2FVecturaDB%2FVecturaDB.Deploy%2Fazure-v1.2.0%2Fazure%2Fvm%2FcreateUiDefinition.json)

The button opens the form of the Azure portal, with the template of the tag `azure-v1.2.0`.

The same template with VecturaDB already chosen as the server, and `vecturadb` as the name:

[![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2FVecturaDB%2FVecturaDB.Deploy%2Fazure-v1.2.0%2Fazure%2Fvm%2Fazuredeploy.json/createUIDefinitionUri/https%3A%2F%2Fraw.githubusercontent.com%2FVecturaDB%2FVecturaDB.Deploy%2Fazure-v1.2.0%2Fazure%2Fvm%2FcreateUiDefinition.vecturadb.json)

When the portal shows "Your deployment is complete", open **Outputs** in the menu on the left: `url` is the address of the server, for the clients.

With the Azure CLI:

```sh
az group create -n my-chroma -l westeurope
az deployment group create -g my-chroma \
  --template-uri https://raw.githubusercontent.com/VecturaDB/VecturaDB.Deploy/azure-v1.2.0/azure/vm/azuredeploy.json \
  -p access=allowed-ips allowedIpRanges='["203.0.113.10/32"]' \
     adminPublicKey="$(cat ~/.ssh/id_ed25519.pub)"
```

For VecturaDB with an API key, add `engine=vecturadb apiKey=<your key>`. The `url` output is the address for the clients.

In our tests a deployment from zero took 157-220 seconds, a new deployment of an existing VM 36-68 seconds.

## Sizes and cost

The sizes we tested, with the list prices of westeurope in USD, for 730 hours a month, on 26 October 2026:

| Size | CPU, memory | VM | OS disk (E4) | Data disk 16 GiB (E3) | Public IP | Total a month |
|---|---|---|---|---|---|---|
| Standard_B2pts_v2 (default, Arm) | 2, 1 GiB | 7.01 | 2.40 | 1.20 | 3.65 | 14.26 |
| Standard_B1s | 1, 1 GiB | 8.76 | 2.40 | 1.20 | 3.65 | 16.01 |
| Standard_B1ms | 1, 2 GiB | 17.52 | 2.40 | 1.20 | 3.65 | 24.77 |

- With internal access there is no public IP: 3.65 less.
- Not in the table: disk transactions (0.002 USD per 10,000 on Standard SSD), outbound traffic, and the snapshots of the backups (see below).
- Standard_B1ls does not work: in our tests it ran out of memory at the first boot, while installing the packages.
- B1s and B1ms belong to the Bv1 series, which Azure lists as [End of Life](https://learn.microsoft.com/en-us/azure/virtual-machines/sizes/general-purpose/bv1-series) with an announced retirement. That is why the default is B2pts_v2.
- The B-series sizes have a baseline CPU and earn credits below it; with credits they can use the whole CPU, and without credits they stay at the baseline: 20% for B2pts_v2 ([Bpsv2 series](https://learn.microsoft.com/en-us/azure/virtual-machines/sizes/general-purpose/bpsv2-series)), 10% for B1s and 20% for B1ms. A server that is busy all the time needs a size outside the B-series.
- A new Azure free account includes, for 12 months, "750 hours each of B1s, B2pts v2 (Arm-based), and B2ats v2 (AMD-based) burstable VMs": see the [Azure free account](https://azure.microsoft.com/en-us/pricing/purchase-options/azure-account) and [what the free services cover](https://learn.microsoft.com/en-us/azure/cost-management-billing/manage/create-free-services).

With 1 GiB of memory, Chroma used 54-61 MiB at rest, with 567-588 MiB free on the VM. We measured only small collections: Chroma keeps its vector index in memory, so a large collection needs a larger size.

## Access, ports and HTTPS

| Access | What is open | Address |
|---|---|---|
| `allowed-ips` | 443 from the IP ranges you give; 80 from anywhere, for the certificate only | `https://<name>-<suffix>.<region>.cloudapp.azure.com`, or your domain |
| `public` | 443 and 80 from anywhere; VecturaDB with an API key only | the same |
| `internal` | nothing from the internet; port 8000 inside the virtual network | `http://<private IP>:8000` |

- Caddy, from its own signed apt repository, gets a Let's Encrypt certificate and forwards to the server on 127.0.0.1:8000.
- Port 80 answers only the challenge of the certificate: Caddy closes every other request. With `allowed-ips`, Caddy also closes the requests from other addresses on 443.
- Ports 22 and 8000 stay closed. The SSH key is for Azure Bastion, or for after you open port 22 yourself.
- The deployment ends only when Caddy holds the certificate. If the certificate does not arrive within 180 seconds, the deployment fails with Caddy's log.
- `cloudapp.azure.com` is not on the Public Suffix List, so [the rate limits of Let's Encrypt](https://letsencrypt.org/docs/rate-limits/) for the Azure names are shared with other users. With `domainName` and a DNS A record to the public IP, the limits are those of your domain.
- Chroma 1.5.9 has no API keys: that is why `public` needs VecturaDB with `apiKey`. VecturaDB reads the key from a file on the VM, readable by root only; every request needs it in the `x-chroma-token` header.

In our tests, from a VM in the same region over HTTPS, a heartbeat took 1.1 ms and a query 2.6 ms (median, Standard_B2pts_v2). We ran the Python (chromadb 1.5.9) and JavaScript (chromadb 3.5.0) clients and a .NET client against both servers: the same results on Chroma and on VecturaDB, and every client refused without the key on VecturaDB.

## Backups and restore

With `backup=disk` (the default), Azure Disk Backup takes incremental snapshots of the data disk, every 24 hours by default (`backupEveryHours`: 4, 6, 8, 12 or 24), and keeps them 7 days (`backupRetentionDays`). The snapshots stay in the resource group. Azure Disk Backup has no fee per protected disk. The snapshots are billed at the price of standard storage, 0.05 USD per GB a month in westeurope: the first one for the used part of the disk, the next ones for the changes. See [Azure Disk Backup](https://learn.microsoft.com/en-us/azure/backup/disk-backup-overview).

Soft delete is on (`backupSoftDelete`): deleted backups stay 14 days, and so does the vault after you delete it. The template never turns on immutability. To remove the whole deployment, see [Delete everything](#delete-everything).

The snapshots are taken while the server runs, so a restored disk is like a disk after a power cut. In our tests the server started on it with all the data of the backup.

To restore:

1. In the backup vault, restore a recovery point to a new disk in the same resource group: Backup instances, then Restore. The template gives the vault the role it needs for that (Disk Restore Operator).
2. Attach the new disk at LUN 1, run `restore.sh` on the VM, then detach and delete the disk:

```sh
az vm disk attach -g my-chroma --vm-name chroma --name <restored disk> --lun 1
az vm run-command invoke -g my-chroma -n chroma --command-id RunShellScript --scripts @restore.sh
az vm disk detach -g my-chroma --vm-name chroma --name <restored disk>
az disk delete -g my-chroma -n <restored disk>
```

`restore.sh` checks the file system of the restored disk and gives it a label of its own. Then it stops the server, replaces the data in `/var/lib/chroma` with the data of the backup, and starts the server again. The data disk stays the same, so the backups go on and a new deployment of the template keeps it. **The data written after the backup is lost**: take an on-demand backup first if you may want it back.

In our tests:

| Step | Time |
|---|---|
| On-demand backup, until the recovery point | 175-179 s |
| Restore to a new disk | 50 s |
| Attach at LUN 1 | 8-40 s |
| `restore.sh` (1 MB of data) | 32-33 s |
| Detach and delete | 11-73 s |

After the restore the server held the data of the backup, and not the data written after it. The next backup worked on the same disk.

## Updates and restarts

- To change the server, its image or the access, deploy the template again with the new parameters. Every deployment runs `configure.sh`, even with the same parameters: it pulls the image, stops the old container (up to 30 seconds), starts the new one and waits for it. The server is down during the switch.
- The data stays on the data disk. In our tests a switch from Chroma 1.5.9 to VecturaDB took 67-68 seconds, and VecturaDB read the collections written by Chroma.
- Docker starts only once the data disk is mounted. A VM that boots without its data disk serves nothing (Caddy answers 502), rather than an empty database.
- Ubuntu installs its security updates by itself (unattended-upgrades), Docker included. Caddy comes from its own repository, which unattended-upgrades leaves out: update it with `apt-get upgrade`, for example through `az vm run-command invoke`.
- In our tests a restart (`az vm restart`) took 73 seconds, and the server answered 11 seconds later, with its data.

## Delete everything

Deleting the resource group deletes the deployment: the VM, the disks, the network, and the snapshots of the backups, which live in the same group. With backups on, two things stop it first:

- the backup instance of the data disk: while it exists, Azure cannot delete the vault;
- soft delete of the vault, on by default: a deleted backup instance stays in the vault for 14 days, and the vault with it.

So, with backups on, turn soft delete off, delete the backup instance, then delete the group. Without backups (`backup=none`), delete the group.

In the portal:

1. Open the backup vault, `<name>-backup`. Under Manage, open Properties. In Cyber recovery settings, on the Soft delete row, select Update, clear Enable Soft Delete, and select Update.
2. Under Manage, open Backup instances. The filter starts on another datasource type, so the list looks empty: set Datasource type to Azure Disks, and open `<name>-data`.
3. Select Delete. Type the name of the instance, choose a reason and write a comment: all three are required. Select Delete, then Confirm.
4. Open the resource group and select Delete resource group. Type the name of the group, select Delete, then Delete again to confirm.

With the Azure CLI:

```sh
SUB=$(az account show --query id -o tsv); RG=my-chroma; NAME=chroma
VAULT="https://management.azure.com/subscriptions/$SUB/resourceGroups/$RG/providers/Microsoft.DataProtection/backupVaults/$NAME-backup"
az rest --method patch --url "$VAULT?api-version=2024-04-01"   --body '{"properties":{"securitySettings":{"softDeleteSettings":{"state":"Off","retentionDurationInDays":14}}}}'
az rest --method delete --url "$VAULT/backupInstances/$NAME-data?api-version=2024-04-01"
# The deletion goes on in the background: wait until the backup instance is gone.
while az rest --method get --url "$VAULT/backupInstances/$NAME-data?api-version=2024-04-01" -o none 2>/dev/null; do sleep 10; done
az group delete -n $RG --yes
```

In our tests, in the portal and with the CLI, soft delete went off at once, the backup instance was gone after 70-103 seconds, and the group after 126-190 seconds. Then nothing was left: no resource, no snapshot, no deleted vault.

If you delete the group without these steps:

- with the backup instance still there, the deletion failed after 438 seconds: "Cannot delete the Backup vault as there are existing backup instances or backup policies in the vault". Everything else was gone, snapshots included; the group and the vault stayed;
- with the backup instance deleted but soft delete still on, the instance stayed in the vault as soft deleted for 14 days, and the deletion of the group failed: "Cannot delete Backup Vault as it contains soft deleted items". The billing of the backup instance ended when we deleted it. The empty vault and the group stay until the 14 days are over. For snapshots that are still there during those days, Microsoft says that the billing goes on at the price of the snapshots ([soft delete for Azure Backup](https://learn.microsoft.com/en-us/azure/backup/secure-by-default)).

To get out of that state before the 14 days: turn soft delete off, undelete the backup instance, delete it again, then delete the group. In our tests that took about 3 minutes:

```sh
az rest --method patch --url "$VAULT?api-version=2024-04-01"   --body '{"properties":{"securitySettings":{"softDeleteSettings":{"state":"Off","retentionDurationInDays":14}}}}'
az rest --method post --url "$VAULT/deletedBackupInstances/$NAME-data/undelete?api-version=2024-04-01"
az rest --method delete --url "$VAULT/backupInstances/$NAME-data?api-version=2024-04-01"
while az rest --method get --url "$VAULT/backupInstances/$NAME-data?api-version=2024-04-01" -o none 2>/dev/null; do sleep 10; done
az group delete -n $RG --yes
```

In a few regions Azure enforces soft delete for backup vaults, and it cannot be turned off there: then the vault stays 14 days after the deletion of its backup instance ([the list of regions](https://learn.microsoft.com/en-us/azure/backup/secure-by-default)). westeurope was not one of them on 27 October 2026.

## Limits

- One VM and one disk: no high availability. While the VM restarts or a deployment switches the container, the server does not answer.
- The backups are snapshots in the same region.
- A new deployment restarts the server even when nothing changes.
- If you attach a disk by hand at LUN 0, use `--caching ReadOnly`, as the template does: a later deployment would otherwise change the caching, and Azure would detach and attach the disk while the VM runs.

## Container Apps, for a few hours of use a day

The [Container Apps template](../container-apps/) runs Chroma 1.5.9 on Azure Container Apps, with the data on an Azure Files share. It scales to zero when nobody uses it, so it costs almost nothing on the days it is idle. It also has limits that this VM does not have: an update made while the app is in use needs a manual step, the first request after scaling to zero waited 26-32 seconds in our tests, reads and writes are slower, and there are no backups and no API keys. See [its limits](../container-apps/#limits).

## License and trademarks

Apache License 2.0, as is, without warranty of any kind.

VecturaDB is an independent fork of Chroma, under the Apache License 2.0. The original code is copyright Chroma Inc. and its contributors.

Not affiliated with, endorsed by or sponsored by Chroma Inc. CHROMA is a registered trademark of Chroma Inc., used here only to describe compatibility.
