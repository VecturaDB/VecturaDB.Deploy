# Chroma on Azure Container Apps

> **Disclaimer.** This template and its scripts are provided as is, without warranty of any kind, as stated in the Apache License 2.0. The numbers below are what we measured on 25, 26, 27 and 28 October and on 6 and 7 November 2026 in westeurope: your region, data and versions may behave differently. You are responsible for your data: back it up, and test a restore on a copy before you rely on it. Not sure about your case? Open an issue in this repository and we will take a look on a best-effort basis.

The template runs **Chroma 1.5.9** (`ghcr.io/chroma-core/chroma:1.5.9`) on Azure Container Apps, with the data on an Azure Files SMB share and backups with Azure Backup. The app scales to zero when nobody uses it, so on the days it is idle you pay almost only for the storage and the backups.

**It is for a few hours of use a day.** For a server in use all day, the [VM template](../vm/) is cheaper, faster and needs no manual step at updates: it is the one we recommend.

## Limits

Read them before you deploy:

- **An update made while the app is in use needs a manual step.** During a change of revision, Container Apps keeps the old revision running until the new one is ready, and both would work on the same files. A lock file in front of the server stops that: the new revision waits until you deactivate the old one (see [Update](#update)). An update made while the app has scaled to zero needs no manual step.
- **A lock can outlive its replica.** If the host of the replica disappears, the share keeps the lock for about 11 minutes (655 seconds in our tests), and the next replica waits for it. See [A lock left by a lost replica](#a-lock-left-by-a-lost-replica).
- **Scale to zero, and a slow first request.** About 10 minutes after the last request (582-613 seconds in our tests) the app has no replica left. The next request starts one: in our tests it waited 26-32 seconds. Set the timeout of your client above that.
- **One replica at most**: no horizontal scale.
- **Slower than the VM.** The data sits on a network share. Medians from a client in the same region, in milliseconds:

  | | VM (B2pts_v2, Standard SSD) | Container Apps (0.5 CPU, 1 GiB, SMB) |
  |---|---|---|
  | query | 2.5 | 5.2-5.7 |
  | count | 2.1 | 4.4-4.5 |
  | get | 4.1 | 8.6-8.8 |
  | add | 112 | 434-448 |
  | small add | 74 | 136-147 |
  | 8 concurrent writers, total | 16.2 s | 25.3-26.2 s |

- **Azure Files and Azure Backup cost too**: the stored data and the transactions of the share, and with backups on 5 USD a month for the share (see [Cost](#cost)).
- **Back up while nobody writes.** A backup taken while the server saves the index of a collection can give that collection back broken. Take the backups while the app has no replica, or with the revision deactivated: see [Backups and restore](#backups-and-restore).
- **No API keys.** Chroma 1.5.9 has none, so the server answers only the IP ranges you allow, or only apps in the same Container Apps environment.

## What it creates

| Resource | Notes |
|---|---|
| Container app | One replica at most, scale to zero, HTTPS ingress on the Azure name of the app |
| Container Apps environment | Consumption plan |
| Storage account and file share | SMB, transaction optimized, 100 GiB quota; soft delete of the share, 7 days |
| Log Analytics workspace | The logs of the app, 30 days by default |
| Recovery Services vault | Only with backups on: Azure Backup of the share, with the snapshots in the storage account |

The server reaches the share through two mounts:

- the data, with `nobrl`: byte-range locks stay on the replica. With the locks sent to the server, Chroma 1.5.9 did not start in our tests;
- the lock file, without `nobrl`: its lock reaches the server, so it holds across replicas and hosts.

## Deploy

[![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2FVecturaDB%2FVecturaDB.Deploy%2Fazure-v1.5.1%2Fazure%2Fcontainer-apps%2Fazuredeploy.json/createUIDefinitionUri/https%3A%2F%2Fraw.githubusercontent.com%2FVecturaDB%2FVecturaDB.Deploy%2Fazure-v1.5.1%2Fazure%2Fcontainer-apps%2FcreateUiDefinition.json)

The button opens the form of the Azure portal, with the template of the tag `azure-v1.5.1`. When the portal shows "Your deployment is complete", open **Outputs** in the menu on the left: `url` is the address of the server, for the clients.

With the Azure CLI:

```sh
az group create -n my-chroma -l westeurope
az deployment group create -g my-chroma \
  --template-uri https://raw.githubusercontent.com/VecturaDB/VecturaDB.Deploy/azure-v1.5.1/azure/container-apps/azuredeploy.json \
  -p allowedIpRanges='["203.0.113.10/32"]'
```

The `url` output is the address for the clients, over HTTPS. In our tests a deployment from zero took 15-18 minutes (881-1067 seconds), most of it for the environment.

## Update

A new deployment with other settings, or another image, creates a new revision. Its replica waits for the lock held by the old one, and the deployment ends anyway. Then deactivate the old revision:

```sh
az containerapp revision list -g my-chroma -n chroma --query "[?properties.active].{name:name, state:properties.runningState}" -o table
az containerapp revision deactivate -g my-chroma -n chroma --revision <the old revision, the one that is not Activating>
```

In our tests the old revision kept serving while the new one waited. After the deactivation the server did not answer for about 6 seconds, then the new revision answered with all the data.

- Deactivate the old revision within 5 minutes. After 5 minutes of waiting the new revision shows Failed; in our tests it started anyway once the old one was deactivated, 22 seconds later.
- An update made while the app has no replica (about 10 minutes after the last request) needs no manual step: nothing holds the lock. In our tests the new revision started at once, the old one went away by itself, and the data was all there.
- With backups on, add `backupAlreadyOn=true` to every new deployment; in the portal, tick "The backups are already on" in Backups. The share stays protected as it is, and the template applies again only the schedule and the days kept. Without it, the template protects the share again while the policy applies itself to the share: Azure Backup starts two configure jobs at the same time, and one of them fails ("Another configure protection operation is in progress for this item"). The share stays protected anyway. Never use it on the first deployment: the share would not be protected. In our tests, with `backupAlreadyOn=true`, the deployment ended in 36-100 seconds, one configure job, from the policy, lasted 1-5 minutes, a change of the days kept was applied, and the next backup worked.

For example, a new deployment with the Azure CLI, the backups on, and the parameters of the first deployment:

```sh
az deployment group create -g my-chroma \
  --template-uri https://raw.githubusercontent.com/VecturaDB/VecturaDB.Deploy/azure-v1.5.1/azure/container-apps/azuredeploy.json \
  -p allowedIpRanges='["203.0.113.10/32"]' backupAlreadyOn=true
```

## A lock left by a lost replica

When the host of the replica disappears without closing its files, Azure Files keeps the lock on the lock file until it gives up on that host: in our tests 655 seconds, about 11 minutes, after the host was switched off. Until then the next replica waits, and the server does not answer.

To free the lock earlier, close only the handle of the lost replica:

```sh
ACCOUNT=$(az storage account list -g my-chroma --query "[0].name" -o tsv)
KEY=$(az storage account keys list -g my-chroma -n $ACCOUNT --query "[0].value" -o tsv)
az storage share list-handle --account-name $ACCOUNT --account-key $KEY --name data --path .lock -o table
az storage share close-handle --account-name $ACCOUNT --account-key $KEY --name data --path .lock \
  --handle-id <the handle of the lost replica>
```

The list shows a handle for each replica that opened the file, with its client IP and the time it was opened: the lost replica is the older one. Never use `--close-all`: in our tests it also closed the handle of the process that was waiting, which then failed with an input/output error.

## Backups and restore

With `backup=files` (the default), Azure Backup takes a snapshot of the share every 24 hours by default (`backupEveryHours`: 4, 6, 8, 12 or 24, the first of the day at 02:00 UTC), and keeps it 7 days (`backupRetentionDays`). A share keeps at most 200 snapshots: up to 200 days with a backup every 24 hours, 99 every 12, 65 every 8, 49 every 6 and 32 every 4. The snapshots stay in the storage account, next to the share. See [Azure Files backup](https://learn.microsoft.com/en-us/azure/backup/azure-file-share-backup-overview).

Azure Backup puts a delete lock on the storage account, `AzureBackupProtectionLock`: nobody can delete the account or the share by mistake. The lock goes away when the account is unregistered from the vault (see [Delete everything](#delete-everything)). The soft delete of Azure Backup does not cover the snapshots of a share; the share has a soft delete of its own, 7 days.

**Take the backups while nobody writes.** A snapshot taken while the server saves the index of a collection holds that index halfway, as a power cut would. In our tests a backup taken a few seconds after 2,000 records were added gave that collection back broken: after the restore it answered "Error getting embedding". This is how Chroma 1.5.9 behaves after a power cut with more than 1,000 records in a collection, not a fault of Azure Backup. The backups taken with the server stopped came back whole, the collections of 1,500 and 2,000 records included:

- the scheduled backup starts within 2 hours of 02:00 UTC. If nobody uses the app then, it has no replica, and the backup holds files that nothing is writing;
- for an on-demand backup, deactivate the revision first, and activate it again after the backup:

```sh
REV=$(az containerapp revision list -g my-chroma -n chroma --query "[0].name" -o tsv)
ACCOUNT=$(az storage account list -g my-chroma --query "[0].name" -o tsv)
az containerapp revision deactivate -g my-chroma -n chroma --revision $REV
JOB=$(az backup protection backup-now -g my-chroma -v chroma-backup -c $ACCOUNT -i data \
  --backup-management-type AzureStorage --workload-type AzureFileShare --query name -o tsv)
az backup job wait -g my-chroma -v chroma-backup -n $JOB
az containerapp revision activate -g my-chroma -n chroma --revision $REV
```

To restore, with the revision deactivated as above, restore a recovery point to the original location of the share, overwriting the files, then activate the revision:

```sh
az backup recoverypoint list -g my-chroma -v chroma-backup -c $ACCOUNT -i data \
  --backup-management-type AzureStorage --workload-type AzureFileShare -o table
JOB=$(az backup restore restore-azurefileshare -g my-chroma -v chroma-backup -c $ACCOUNT -i data -r <recovery point> \
  --resolve-conflict Overwrite --restore-mode OriginalLocation --query name -o tsv)
az backup job wait -g my-chroma -v chroma-backup -n $JOB
az containerapp revision activate -g my-chroma -n chroma --revision $REV
```

In the portal the same restore is Restore Share in the backup item of the share, with Original Location and Overwrite ([Microsoft's steps](https://learn.microsoft.com/en-us/azure/backup/restore-afs)); we tested it with the Azure CLI only.

**The data written after the backup is lost**: take an on-demand backup first if you may want it back. The restore overwrites the files of the backup and leaves the others: the folders of the collections created after the backup stay in the share, and the server does not use them.

In our tests:

| Step | Time |
|---|---|
| Deactivation of the revision, until no replica | 35-43 s |
| On-demand backup, the job | 3-5 s |
| Restore to the original location, the job | 33-188 s |
| Activation, until the server answers | 25-45 s |
| From the last request to zero replicas | 582 s |

`az backup job wait` came back up to 3 minutes after the end of the job.

After the restores the server held the collections of the backup, with all their records, and not the ones written after it. The next backup worked on the same share.

## Cost

Container Apps bills the seconds a replica runs: active while it serves, at a lower rate while it waits before scaling to zero (about 10 minutes after each use). The first 180,000 vCPU-seconds, 360,000 GiB-seconds and 2 million requests of each month are free, for the whole subscription. With 0.5 CPU and 1 GiB, at the list prices of westeurope in USD on 27 October 2026:

| Use | Container Apps, with the free grant | Without the free grant | VM template (B2pts_v2) |
|---|---|---|---|
| In use all day, every day | 47.63 | 55.19 | 14.26 |
| 8 hours a day | 10.69 | 18.25 | 14.26 |
| 3 hours a day | 0.00 | 6.91 | 14.26 |
| One hour a month | 0.00 | 0.09 | 14.26 |

Not in the table:

- Azure Files: 0.06 USD per GB stored a month, and the transactions. In our tests a write to Chroma cost about 27 transactions of the share, mostly write transactions: about 0.03 USD for every 1,000 writes. Reads cost almost none. A replica that waits without requests made about 27 transactions a minute.
- Azure Backup, with backups on (the default): 5 USD a month for the protected share, at the list prices of westeurope on 6 November 2026. Azure Files bills the snapshots at the price of the share, 0.06 USD per GB a month, for the data that changed since the snapshot before.
- Log Analytics bills the logs it receives.
- Other apps in the same subscription use the same free grant.

## Delete everything

Without backups (`backup=none`), deleting the resource group deletes the whole deployment. With backups on, two things stop the deletion first: the lock of Azure Backup on the storage account, and the share protected in the vault. So stop the protection and delete its backup data, unregister the storage account, which also removes the lock, then delete the group:

```sh
ACCOUNT=$(az storage account list -g my-chroma --query "[0].name" -o tsv)
az backup protection disable -g my-chroma -v chroma-backup -c $ACCOUNT -i data \
  --backup-management-type AzureStorage --workload-type AzureFileShare --delete-backup-data true --yes
az backup container unregister -g my-chroma -v chroma-backup -c $ACCOUNT --backup-management-type AzureStorage --yes
az lock list -g my-chroma -o table
az group delete -n my-chroma --yes
```

In our tests `az backup container unregister` answered `CloudInternalError` every time, also 3 minutes after the end of the protection, but the account was unregistered: the lock was gone at once, and the group was then deleted. Before the deletion of the group, `az lock list` must show no lock.

In the portal: in the vault `chroma-backup`, stop the backup of the share with Delete Backup Data, then unregister the storage account under Backup Infrastructure ([Microsoft's steps](https://learn.microsoft.com/en-us/azure/backup/manage-afs-backup#stop-protection-on-a-file-share)). Then open the resource group and select Delete resource group, type the name of the group, select Delete, then Delete again to confirm. We tested the deletion with the Azure CLI only.

In our tests:

| Step | Time |
|---|---|
| Protection stopped, backup data deleted | 33-104 s |
| Storage account unregistered | 18-44 s |
| Resource group deleted, most of it for the Container Apps environment | 27-30 minutes (1632-1817 s) |

Three things stay recoverable for 14 days after the deletion, as Azure does for these resources, and then go away. In our tests they showed up in the lists of deleted resources right after the deletion:

- the vault, empty, in soft delete: Azure purges it 14 days after the protection was stopped ([soft delete for Azure Backup](https://learn.microsoft.com/en-us/azure/backup/secure-by-default));
- the storage account, with the share and the data in it ([recover a deleted storage account](https://learn.microsoft.com/en-us/azure/storage/common/storage-account-recover));
- the Log Analytics workspace, with the logs ([delete and recover a workspace](https://learn.microsoft.com/en-us/azure/azure-monitor/logs/delete-workspace)). To remove the logs at once, delete the workspace permanently before the group:

```sh
az monitor log-analytics workspace delete -g my-chroma -n chroma-logs --force --yes
```

## Why the VM is the recommended choice

On the [VM](../vm/) the data is on a local managed disk: reads are about twice as fast and writes 2 to 4 times, an update needs no manual step, the server never sleeps, and Azure Disk Backup has no fee per protected disk. From about 14 USD a month, whatever the use.

## License and trademarks

Apache License 2.0, as is, without warranty of any kind.

VecturaDB is an independent fork of Chroma, under the Apache License 2.0. The original code is copyright Chroma Inc. and its contributors.

Not affiliated with, endorsed by or sponsored by Chroma Inc. CHROMA is a registered trademark of Chroma Inc., used here only to describe compatibility.
