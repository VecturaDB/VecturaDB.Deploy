# Chroma or VecturaDB on one AWS EC2 instance

<!-- DRAFT, not published. The ⟨...⟩ marks wait for the public bucket of the Launch Stack button and for the test from the button. -->

> **Disclaimer.** This template and its scripts are provided as is, without warranty of any kind, as stated in the Apache License 2.0. The numbers below are what we measured on 29 October 2026 in eu-west-1: your region, sizes, data and versions may behave differently. You are responsible for your data: back it up, and test a restore on a copy before you rely on it. Not sure about your case? Open an issue in this repository and we will take a look on a best-effort basis.

The template runs one server in your own AWS account, with its data on an EBS volume:

- **Chroma 1.5.9** (`ghcr.io/chroma-core/chroma:1.5.9`, the same image as `chromadb/chroma` on Docker Hub), or
- **VecturaDB 1.0.0-preview.3.post1** (`ghcr.io/vecturadb/vecturadb:1.0.0-preview.3.post1`), built from Chroma, with sparse vectors, BM25, the Search API, collection fork and API keys.

Both servers keep the Chroma API, so the Chroma clients connect with the URL of the stack.

## What it creates

| Resource | Notes |
|---|---|
| EC2 instance, Ubuntu 24.04 | Docker runs the server; Caddy serves HTTPS in front of it |
| EBS data volume, gp3 | Mounted at `/var/lib/chroma`; 16 GiB by default, encrypted |
| Security group | Opens only what the access mode needs |
| VPC, subnet and internet gateway | 10.42.0.0/16, in the first availability zone of the region |
| Elastic IP | The address for HTTPS, and the way out to the package and image registries, also with internal access |
| IAM role of the instance | Systems Manager runs the configuration and the restore: there is no SSH |
| Systems Manager documents and association | The configuration, run at the creation and at every update that changes it; the restore |
| Secrets Manager secret | Only VecturaDB with an API key |
| Data Lifecycle Manager policy | Only with backups on: snapshots of the data volume |

Files:

- `template.yaml`: the template, with the scripts of the first boot, of the configuration and of the restore inside it.

## Deploy

⟨The Launch Stack button: CloudFormation reads a template only from Amazon S3.⟩

The button opens the quick-create page of CloudFormation in eu-west-1, with the template and the name of the stack already filled in:

1. Fill the parameters, in three groups: Server (engine, images, instance type, size of the data volume), Access (access mode, allowed IP ranges, API key, domain, email for Let's Encrypt) and Backups.
2. Under "Capabilities and transforms", tick the three acknowledgements: IAM resources, IAM resources with custom names, and `CAPABILITY_AUTO_EXPAND`.
3. Choose "Create stack". When the status is `CREATE_COMPLETE`, the Outputs tab has the `Url` for the clients.

With the AWS CLI, from a copy of `template.yaml`:

```sh
aws cloudformation create-stack --region eu-west-1 --stack-name my-chroma \
  --template-body file://template.yaml \
  --capabilities CAPABILITY_IAM CAPABILITY_AUTO_EXPAND \
  --parameters ParameterKey=Access,ParameterValue=allowed-ips \
               ParameterKey=AllowedIpRanges,ParameterValue=203.0.113.10/32
aws cloudformation wait stack-create-complete --region eu-west-1 --stack-name my-chroma
aws cloudformation describe-stacks --region eu-west-1 --stack-name my-chroma --query "Stacks[0].Outputs"
```

For VecturaDB with an API key, add `ParameterKey=Engine,ParameterValue=vecturadb ParameterKey=ApiKey,ParameterValue=<your key>`. The `Url` output is the address for the clients.

The two capabilities are needed because the stack creates IAM roles, and because it uses `AWS::LanguageExtensions` for one security group rule for each allowed range.

In our tests a stack from zero took 400-608 seconds, until the server answered over HTTPS, and an update of an existing stack 34-126 seconds. Most of the creation is the first boot of the instance, which installs Docker and Caddy. A new instance in standard credit mode (see Sizes and cost) has no CPU credits yet, so it runs at the baseline CPU: in both our tests the CPU credit balance of the instance was 0 during the first boot.

## Sizes and cost

The sizes we tested, with the list prices of eu-west-1 in USD, for 730 hours a month, on 29 October 2026:

| Size | CPU, memory | Instance | Root volume 8 GiB (gp3) | Data volume 16 GiB (gp3) | Public IPv4 | Total a month |
|---|---|---|---|---|---|---|
| t4g.micro (default, Arm) | 2, 1 GiB | 6.72 | 0.70 | 1.41 | 3.65 | 12.48 |
| t4g.small (Arm) | 2, 2 GiB | 13.43 | 0.70 | 1.41 | 3.65 | 19.19 |

- With internal access the Elastic IP stays: it is the way out to the internet, as there is no NAT gateway.
- VecturaDB with an API key adds the secret: 0.40 USD a month, plus 0.05 USD per 10,000 reads.
- Not in the table: outbound traffic, and the snapshots of the backups (see below).
- The t4g and t3 types have a baseline CPU and earn credits below it: 10% of each vCPU for t4g.micro and t3.micro, 20% for the small and medium sizes ([the credit table](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/burstable-credits-baseline-concepts.html)). The stack sets the standard credit mode: without credits the CPU stays at the baseline, and nothing is billed beyond the price of the instance. In unlimited mode, the default of AWS for these types, the CPU above the baseline is billed. A server that is busy all the time needs a larger size.

With 1 GiB of memory (904 MiB for the system), Chroma used 10 MiB at rest and 93 MiB after our operations bench, with 450-502 MiB available on the instance. We measured only small collections: Chroma keeps its vector index in memory, so a large collection needs a larger size.

## Access, ports and HTTPS

| Access | What is open | Address |
|---|---|---|
| `allowed-ips` | 443 from the IP ranges you give; 80 from anywhere, for the certificate only | `https://<Elastic IP>`, or your domain |
| `public` | 443 and 80 from anywhere; VecturaDB with an API key only | the same |
| `internal` | nothing from the internet; port 8000 inside the VPC | `http://<private IP>:8000` |

- Caddy, from its own signed apt repository, gets a Let's Encrypt certificate and forwards to the server on 127.0.0.1:8000.
- Let's Encrypt gives no certificate for the names that AWS gives to instances (`*.amazonaws.com`). Without `DomainName`, the certificate is for the Elastic IP itself: Let's Encrypt issues those only with its short-lived profile, and Caddy renews them. In our tests Caddy had the certificate 16 seconds after it started, valid for 160 hours, and the Python, JavaScript and .NET clients accepted it.
- Clients send no server name (SNI) to an IP address, and the instance sees its private address, not the Elastic IP: the stack gives Caddy the Elastic IP as the default name, so that it finds the certificate.
- With `DomainName` and a DNS A record to the Elastic IP (the `PublicIp` output), the certificate is for your domain. The Elastic IP stays the same across updates: deploy first without the domain, create the record, then update the stack with `DomainName`.
- Port 80 answers only the challenge of the certificate: Caddy closes every other request. With `allowed-ips`, Caddy also closes the requests from other addresses on 443.
- Port 22 stays closed and the instance has no key pair. For a shell, use Session Manager: `aws ssm start-session --target <InstanceId>`, with the Session Manager plugin of the AWS CLI.
- The stack is complete only when the configuration has finished: Caddy holds the certificate and the server answers. At the creation the configuration signals its end to the stack, because in our tests Systems Manager alone once let the stack complete five minutes before the server answered. If the certificate does not arrive within 180 seconds, the configuration fails with Caddy's log. ⟨To verify: the rollback after a failure.⟩
- Chroma 1.5.9 has no API keys: that is why `public` needs VecturaDB with `ApiKey`. The stack keeps the key in Secrets Manager; the instance writes it to a file readable by root only. Every request needs it in the `x-chroma-token` header.

In our tests we ran the Python (chromadb 1.5.9) and JavaScript (chromadb 3.5.0) clients and a .NET client over HTTPS on the Elastic IP, against both servers: the same results on Chroma and on VecturaDB, and VecturaDB answered 401 without the key. On the instance, against the server on 127.0.0.1:8000 (t4g.micro, median of 20 runs): a query took 2.2 ms, a get 4.2 ms, an add of 2 records 35 ms, and 8 concurrent writers 6.1 seconds in all.

## Backups and restore

With `Backup=snapshots` (the default), Amazon Data Lifecycle Manager takes snapshots of the data volume, every 24 hours by default (`BackupEveryHours`: 4, 6, 8, 12 or 24), and keeps them 7 days (`BackupRetentionDays`). Data Lifecycle Manager has no fee. The snapshots are billed at 0.05 USD per GB a month in eu-west-1: the first one for the used part of the volume, the next ones for the changes. **The snapshots are not part of the stack**: deleting the stack leaves them, see [Delete everything](#delete-everything).

The snapshots are taken while the server runs, so a restored volume is like a volume after a power cut: in our tests its file system recovered its journal, and the server started on it with all the data of the snapshot.

To list the snapshots:

```sh
aws ec2 describe-snapshots --region eu-west-1 --owner-ids self \
  --filters Name=tag:chroma-backup,Values=my-chroma --query "Snapshots[].[SnapshotId,StartTime,State]" --output table
```

To restore, create a volume from a snapshot in the availability zone of the instance, attach it, run the `RestoreDocument` of the stack, then detach and delete the volume:

```sh
STACK=my-chroma; SNAPSHOT=<snapshot id>
out() { aws cloudformation describe-stacks --stack-name $STACK --query "Stacks[0].Outputs[?OutputKey=='$1'].OutputValue" --output text; }
INSTANCE=$(out InstanceId); DOCUMENT=$(out RestoreDocument)
AZ=$(aws ec2 describe-instances --instance-ids $INSTANCE --query "Reservations[0].Instances[0].Placement.AvailabilityZone" --output text)
VOLUME=$(aws ec2 create-volume --snapshot-id $SNAPSHOT --availability-zone $AZ --volume-type gp3 --encrypted --query VolumeId --output text)
aws ec2 wait volume-available --volume-ids $VOLUME
aws ec2 attach-volume --volume-id $VOLUME --instance-id $INSTANCE --device /dev/sdg
aws ec2 wait volume-in-use --volume-ids $VOLUME
COMMAND=$(aws ssm send-command --document-name $DOCUMENT --instance-ids $INSTANCE --parameters volumeId=$VOLUME --query Command.CommandId --output text)
until aws ssm get-command-invocation --command-id $COMMAND --instance-id $INSTANCE --query Status --output text 2>/dev/null | grep -qE 'Success|Failed|Cancelled|TimedOut'; do sleep 5; done
aws ssm get-command-invocation --command-id $COMMAND --instance-id $INSTANCE --query "[Status,StandardOutputContent]" --output text
aws ec2 detach-volume --volume-id $VOLUME
aws ec2 wait volume-available --volume-ids $VOLUME
aws ec2 delete-volume --volume-id $VOLUME
```

The restore checks the file system of the restored volume and gives it a label of its own. Then it stops the server, replaces the data in `/var/lib/chroma` with the data of the snapshot, and starts the server again. The data volume stays the same, so the snapshots go on and the stack keeps it. **The data written after the snapshot is lost**: take a snapshot first if you may want it back (`aws ec2 create-snapshot --volume-id <DataVolumeId>`; Data Lifecycle Manager does not delete the snapshots you take by hand).

In our tests:

| Step | Time |
|---|---|
| Snapshot by hand, until completed | 49 s |
| Volume from the snapshot | 4 s |
| Attach | 3-5 s |
| `RestoreDocument` (5.6 MB of data) | 11-12 s |
| Detach and delete | 6-21 s |

After the restore the server held the data of the snapshot, 4,400 records written before it, and none of the records written after it.

## Updates and restarts

- To change the server, its image or the access, update the stack with the new parameters. When they change, Systems Manager runs the configuration again: it pulls the image, stops the old container (up to 30 seconds), starts the new one and waits for it. The server is down during the switch. An update that changes none of them does not restart the server.
- The data stays on the data volume. In our tests a switch from Chroma 1.5.9 to VecturaDB with an API key took 65 seconds, and VecturaDB read the collections written by Chroma; a change of access took 34 seconds.
- After a switch, the configuration deletes the image it replaced, so that the root volume of 8 GiB does not fill up update after update.
- The image of the operating system is the latest Ubuntu 24.04 at the creation of the stack. An update never replaces the instance, so it never moves the data volume. Ubuntu installs its security updates by itself (unattended-upgrades), Docker included. Caddy comes from its own repository, which unattended-upgrades leaves out: update it with `apt-get upgrade`, for example through `aws ssm send-command --document-name AWS-RunShellScript`.
- A change of `InstanceType` within the same family stops and starts the same instance: in our tests, from t4g.micro to t4g.small, the update took 65 seconds and the server did not answer for about 30. A change between t4g (Arm) and t3 (x86) changes the image of the operating system: it needs a new stack and a restore.
- Docker starts only once the data volume is mounted. An instance that boots without its data volume serves nothing, rather than an empty database.
- In our tests the server answered 24 seconds after a reboot of the instance, with its data.

## Delete everything

Deleting the stack deletes the instance, the data volume, the network, the Elastic IP, the roles, the documents and the secret. The snapshots stay: those of Data Lifecycle Manager, and those you took by hand. Delete them yourself, after the stack, so that no new snapshot comes after the cleanup:

```sh
aws cloudformation delete-stack --region eu-west-1 --stack-name my-chroma
aws cloudformation wait stack-delete-complete --region eu-west-1 --stack-name my-chroma
for s in $(aws ec2 describe-snapshots --region eu-west-1 --owner-ids self \
    --filters Name=tag:chroma-backup,Values=my-chroma --query "Snapshots[].SnapshotId" --output text); do
  aws ec2 delete-snapshot --region eu-west-1 --snapshot-id $s
done
```

In the console: select the stack, choose "Delete" and type the name of the stack to confirm. Then, in EC2 > Snapshots, delete the snapshots with the tag `chroma-backup` equal to the name of the stack.

In our tests the deletion of the stack took 40-64 seconds, with and without the API key; afterwards nothing of the stack was left in the region. CloudFormation deleted the secret at once: it was not left among the secrets scheduled for deletion.

## Limits

- One instance and one volume: no high availability. While the instance restarts or an update switches the container, the server does not answer.
- The snapshots are in the same region.
- The subnet is in the first availability zone of the region. In eu-west-1 all three zones offer t4g.micro; where the first zone does not offer a type, choose another one.
- The certificate of an IP address is valid for about 6 days: Caddy renews it while the instance runs.

## License and trademarks

Apache License 2.0, as is, without warranty of any kind.

VecturaDB is an independent fork of Chroma, under the Apache License 2.0. The original code is copyright Chroma Inc. and its contributors.

Not affiliated with, endorsed by or sponsored by Chroma Inc. CHROMA is a registered trademark of Chroma Inc., used here only to describe compatibility.
