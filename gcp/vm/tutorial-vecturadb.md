# VecturaDB on one Compute Engine VM

<walkthrough-tutorial-duration duration="15"></walkthrough-tutorial-duration>

This guide runs Terraform in Cloud Shell and creates, in a project of yours:

- one e2-micro VM with Ubuntu 24.04, where Docker runs VecturaDB and Caddy serves HTTPS in front of it. VecturaDB is built from Chroma and keeps the Chroma API, with sparse vectors, BM25, the Search API, collection fork and API keys;
- a data disk of 16 GB, with a snapshot every 24 hours kept for 7 days;
- a static IP address, a VPC and firewall rules: HTTPS only from the IP addresses you allow;
- with an API key, a secret in Secret Manager that only the VM may read.

In europe-west1 it costs about 12.98 USD a month on your Google Cloud bill, at the list prices of 4 November 2026, plus the snapshots, the outbound traffic and, with an API key, the secret. The template is free.

Run the commands in the order of the guide, in the same terminal: each step uses what the previous ones set.

## Choose the project

<walkthrough-project-setup billing="true"></walkthrough-project-setup>

Set it in the terminal:

```sh
gcloud config set project <walkthrough-project-id/>
```

## Sign in

A Cloud Shell opened from a repository that you did not mark as trusted is temporary, and has no credentials. The first command signs you in only when they are missing: gcloud first says that you are already authenticated, answer `Y`; then open the link it prints, sign in with the account of the project, and paste the code in the terminal. In a Cloud Shell with your credentials, Google may ask to authorize Cloud Shell instead: choose Authorize.

The second command gives that sign-in to Terraform too: in a temporary Cloud Shell, Terraform does not find it by itself.

When a temporary Cloud Shell opens, Google may also ask to authorize Cloud Shell: it is not needed there, click outside it to close it.

```sh
gcloud auth print-access-token >/dev/null 2>&1 || gcloud auth login --update-adc
[ -f "$CLOUDSDK_CONFIG/application_default_credentials.json" ] && export GOOGLE_APPLICATION_CREDENTIALS=$CLOUDSDK_CONFIG/application_default_credentials.json
```

## Install Terraform

Cloud Shell has no Terraform: the commands install it from the repository of HashiCorp.

```sh
wget -qO- https://apt.releases.hashicorp.com/gpg | sudo gpg --dearmor --yes -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/hashicorp.list >/dev/null
sudo apt-get update -qq && sudo apt-get install -y -qq terraform && hash -r && terraform version
```

## Prepare the project

The first command turns on the APIs that the template uses, Compute Engine, IAM, Secret Manager and Cloud Storage, where they are off.

Terraform keeps what it created in a state. The state goes to a Cloud Storage bucket of the project, so that a later update or deletion finds it from any Cloud Shell. A bucket that is already there stays as it is.

```sh
gcloud services enable compute.googleapis.com iam.googleapis.com secretmanager.googleapis.com storage.googleapis.com
export TF_VAR_project_id=$(gcloud config get-value project) && export BUCKET=$TF_VAR_project_id-chroma-tfstate
gcloud storage buckets describe gs://$BUCKET >/dev/null 2>&1 || gcloud storage buckets create gs://$BUCKET --location=europe-west1 --uniform-bucket-level-access --public-access-prevention
gcloud storage buckets update gs://$BUCKET --versioning
terraform init -reconfigure -backend-config=bucket=$BUCKET -backend-config=prefix=vecturadb
```

## Settings

A deployment made before keeps its settings in the bucket: the command gets them back, if they are there.

```sh
gcloud storage cp gs://$BUCKET/vecturadb/vecturadb.tfvars . 2>/dev/null && echo "Settings of the deployment" || echo "New deployment"
```

For a new deployment, or when the IP address of your computer has changed: the public IP address of your computer, the one that Google shows when you search "what is my ip", may reach the server.

```sh
read -p "IP address of your computer: " IP && sed -i '/allowed_ip_ranges *=/d' vecturadb.tfvars && printf 'allowed_ip_ranges = ["%s/32"]\n' "$IP" >> vecturadb.tfvars
```

The other settings are in <walkthrough-editor-open-file filePath="vecturadb.tfvars">vecturadb.tfvars</walkthrough-editor-open-file>: region and zone, size of the VM, access from anywhere, more IP ranges, your own domain name, snapshots.

## API key

With a key, every request needs it in the `x-chroma-token` header. It is optional with the allowed IP addresses, and required with access from anywhere (`access = "public"`). It needs at least 16 characters; the command makes one:

```sh
openssl rand -hex 24
```

Keep the key: the clients need it, and the deployment does not show it again. Type it here, or leave it empty for no key:

```sh
read -rsp "API key: " TF_VAR_api_key && export TF_VAR_api_key && echo
```

The key goes to Secret Manager only, not to the state or to the settings file. At every later change give the same key again, or a new one to change it: a change without the key removes it.

## Create the server

```sh
terraform apply -parallelism=2 -var-file=vecturadb.tfvars && gcloud storage cp vecturadb.tfvars gs://$BUCKET/vecturadb/
```

Terraform lists what it creates: type `yes`. It ends when the server answers over HTTPS, with a certificate of Let's Encrypt. Then it saves the settings in the bucket.

The `url` output is the address for the Chroma clients, for example in Python:

```python
import chromadb
client = chromadb.HttpClient(host="<public_ip>", port=443, ssl=True, headers={"x-chroma-token": "<API key>"})
```

## Change or delete

To change a setting later, open the guide again with the same button and repeat all the steps: the Settings step gets the saved settings back, and `terraform apply` changes only what differs. A change of the server, of the access or of the key restarts the container: the data stays on the data disk.

To delete everything, after the steps up to Settings:

```sh
terraform destroy -parallelism=2 -var-file=vecturadb.tfvars && for s in $(gcloud compute snapshots list --filter="labels.chroma-backup=vecturadb" --format="value(name)" --verbosity=error); do gcloud compute snapshots delete $s --quiet; done && gcloud storage rm --recursive --all-versions gs://$BUCKET/vecturadb
```

The snapshots are not part of the deployment. Only after `terraform destroy` has ended without errors, the command deletes them, then the state and the settings in the bucket. `gcloud storage rm --recursive --all-versions gs://$BUCKET` deletes the bucket too, when it holds no other deployment.

Restore of a snapshot, updates and limits: see the README of the template, in the `gcp/vm` folder of the repository.

## Done

<walkthrough-conclusion-trophy></walkthrough-conclusion-trophy>

The server is on the `url` output. The deployment and its settings are in the bucket of the state, ready for the next change.
