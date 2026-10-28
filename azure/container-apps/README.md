# Chroma on Azure Container Apps

> **Disclaimer.** This template and its scripts are provided as is, without warranty of any kind, as stated in the Apache License 2.0. The numbers below are what we measured on 25, 26, 27 and 28 October 2026 in westeurope: your region, data and versions may behave differently. You are responsible for your data: back it up, and test a restore on a copy before you rely on it. Not sure about your case? Open an issue in this repository and we will take a look on a best-effort basis.

The template runs **Chroma 1.5.9** (`ghcr.io/chroma-core/chroma:1.5.9`) on Azure Container Apps, with the data on an Azure Files SMB share. The app scales to zero when nobody uses it, so it costs almost nothing on the days it is idle.

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

- **Azure Files costs too**: the stored data and the transactions of the share (see [Cost](#cost)).
- **No backups.** The template does not back up the share. Soft delete keeps a deleted share for 7 days, but it does not bring back data that was changed or deleted inside it.
- **No API keys.** Chroma 1.5.9 has none, so the server answers only the IP ranges you allow, or only apps in the same Container Apps environment.

## What it creates

| Resource | Notes |
|---|---|
| Container app | One replica at most, scale to zero, HTTPS ingress on the Azure name of the app |
| Container Apps environment | Consumption plan |
| Storage account and file share | SMB, transaction optimized, 100 GiB quota; soft delete of the share, 7 days |
| Log Analytics workspace | The logs of the app, 30 days by default |

The server reaches the share through two mounts:

- the data, with `nobrl`: byte-range locks stay on the replica. With the locks sent to the server, Chroma 1.5.9 did not start in our tests;
- the lock file, without `nobrl`: its lock reaches the server, so it holds across replicas and hosts.

## Deploy

[![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2FVecturaDB%2FVecturaDB.Deploy%2Fazure-v1.1.0%2Fazure%2Fcontainer-apps%2Fazuredeploy.json/createUIDefinitionUri/https%3A%2F%2Fraw.githubusercontent.com%2FVecturaDB%2FVecturaDB.Deploy%2Fazure-v1.1.0%2Fazure%2Fcontainer-apps%2FcreateUiDefinition.json)

The button opens the form of the Azure portal, with the template of the tag `azure-v1.1.0`. When the portal shows "Your deployment is complete", open **Outputs** in the menu on the left: `url` is the address of the server, for the clients.

With the Azure CLI:

```sh
az group create -n my-chroma -l westeurope
az deployment group create -g my-chroma \
  --template-uri https://raw.githubusercontent.com/VecturaDB/VecturaDB.Deploy/azure-v1.1.0/azure/container-apps/azuredeploy.json \
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
- Log Analytics bills the logs it receives.
- Other apps in the same subscription use the same free grant.

## Delete everything

There is no backup vault here: deleting the resource group deletes the whole deployment. In our tests it took 27-30 minutes (1632-1810 seconds), most of it for the Container Apps environment.

In the portal, open the resource group and select Delete resource group. Type the name of the group, select Delete, then Delete again to confirm.

With the Azure CLI:

```sh
az group delete -n my-chroma --yes
```

Two things stay recoverable for 14 days after the deletion, as Azure does for these resources, and then go away. In our tests both showed up in the lists of deleted resources right after the deletion:

- the storage account, with the share and the data in it ([recover a deleted storage account](https://learn.microsoft.com/en-us/azure/storage/common/storage-account-recover));
- the Log Analytics workspace, with the logs ([delete and recover a workspace](https://learn.microsoft.com/en-us/azure/azure-monitor/logs/delete-workspace)). To remove the logs at once, delete the workspace permanently before the group:

```sh
az monitor log-analytics workspace delete -g my-chroma -n chroma-logs --force --yes
```

## Why the VM is the recommended choice

On the [VM](../vm/) the data is on a local managed disk: reads are about twice as fast and writes 2 to 4 times, an update needs no manual step, the server never sleeps, and backups with Azure Disk Backup are part of the template. From about 14 USD a month, whatever the use.

## License and trademarks

Apache License 2.0, as is, without warranty of any kind.

VecturaDB is an independent fork of Chroma, under the Apache License 2.0. The original code is copyright Chroma Inc. and its contributors.

Not affiliated with, endorsed by or sponsored by Chroma Inc. CHROMA is a registered trademark of Chroma Inc., used here only to describe compatibility.
