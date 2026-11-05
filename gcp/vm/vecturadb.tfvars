# Settings of a deployment with VecturaDB, for terraform apply -var-file=vecturadb.tfvars. The guide of Cloud Shell
# saves this file in the state bucket, next to the state, and gets it back for an update. The project comes from
# TF_VAR_project_id, the API key from TF_VAR_api_key: the key is never written in this file. All the settings are in
# variables.tf.

# Name of the VM and prefix of the other resources. The guide uses it also as the folder of the state in the bucket.
name   = "vecturadb"
engine = "vecturadb"

region = "europe-west1"
zone   = "europe-west1-b"

# e2-micro (2 shared vCPU, 1 GB), e2-small (2 GB) or e2-medium (4 GB).
machine_type = "e2-micro"

# allowed-ips: HTTPS only from the ranges below. public: HTTPS from anywhere, with an API key only. internal: only the
# VPC of the deployment, HTTP on port 8000.
access = "allowed-ips"

# Optional: your own domain name, with a DNS A record to the public IP, and an email for Let's Encrypt.
domain_name = ""
acme_email  = ""

data_disk_size_gb = 16

# Snapshots of the data disk (snapshots or none), every 4, 6, 8, 12 or 24 hours, kept for the given days.
backup                = "snapshots"
backup_every_hours    = 24
backup_retention_days = 7

# IP ranges that may reach the server, like ["203.0.113.10/32"] for one address.
allowed_ip_ranges = []
