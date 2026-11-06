variable "project_id" {
  description = "The Google Cloud project of the deployment."
  type        = string
}

variable "region" {
  description = "Region of the resources."
  type        = string
  default     = "europe-west1"
}

variable "zone" {
  description = "Zone of the VM and of its disks, in the region."
  type        = string
  default     = "europe-west1-b"
}

variable "name" {
  description = "Name of the VM, and prefix of the other resources: 3 to 20 lowercase letters, digits and hyphens."
  type        = string
  default     = "chroma"
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,18}[a-z0-9]$", var.name))
    error_message = "3 to 20 lowercase letters, digits and hyphens, starting with a letter."
  }
}

variable "engine" {
  description = "The server: chroma (Chroma 1.5.9) or vecturadb (VecturaDB, built from Chroma, with sparse vectors, BM25, the Search API, collection fork and API keys)."
  type        = string
  default     = "chroma"
  validation {
    condition     = contains(["chroma", "vecturadb"], var.engine)
    error_message = "chroma or vecturadb."
  }
}

variable "chroma_image" {
  description = "Image of Chroma. The same image is on Docker Hub as chromadb/chroma."
  type        = string
  default     = "ghcr.io/chroma-core/chroma:1.5.9"
}

variable "vecturadb_image" {
  description = "Image of VecturaDB."
  type        = string
  default     = "ghcr.io/vecturadb/vecturadb:1.0.0-preview.8"
}

variable "machine_type" {
  description = "Machine type: e2-micro (2 shared vCPU, 1 GB), e2-small (2 shared vCPU, 2 GB) or e2-medium (2 shared vCPU, 4 GB)."
  type        = string
  default     = "e2-micro"
  validation {
    condition     = contains(["e2-micro", "e2-small", "e2-medium"], var.machine_type)
    error_message = "e2-micro, e2-small or e2-medium."
  }
}

variable "access" {
  description = "Who reaches the server: allowed-ips (HTTPS from the allowed IP ranges), public (HTTPS from anywhere, VecturaDB with an API key only) or internal (only the VPC of the deployment, HTTP on the private address, port 8000)."
  type        = string
  default     = "allowed-ips"
  validation {
    condition     = contains(["allowed-ips", "public", "internal"], var.access)
    error_message = "allowed-ips, public or internal."
  }
}

variable "allowed_ip_ranges" {
  description = "IP ranges in CIDR notation that may reach the server over HTTPS when access is allowed-ips, like [\"203.0.113.10/32\"]."
  type        = list(string)
  default     = []
}

variable "api_key" {
  description = "VecturaDB only: the API key of the admin user, at least 16 characters. Every request then needs it, in the x-chroma-token header. Required when access is public. The deployment keeps it in Secret Manager, not in the state: give it again at every apply, as an apply without it removes the key."
  type        = string
  default     = ""
  sensitive   = true
}

variable "domain_name" {
  description = "Your own domain name for HTTPS, like chroma.example.com, with a DNS A record to the public IP (output public_ip). Empty: a certificate for the public IP itself."
  type        = string
  default     = ""
}

variable "acme_email" {
  description = "Email for the account of the HTTPS certificate at Let's Encrypt. Optional."
  type        = string
  default     = ""
}

variable "data_disk_size_gb" {
  description = "Size of the data disk in GB (pd-balanced)."
  type        = number
  default     = 16
}

variable "backup" {
  description = "Backups of the data disk: snapshots (a snapshot schedule of Compute Engine) or none."
  type        = string
  default     = "snapshots"
  validation {
    condition     = contains(["snapshots", "none"], var.backup)
    error_message = "snapshots or none."
  }
}

variable "backup_every_hours" {
  description = "Hours between two snapshots of the data disk: 4, 6, 8, 12 or 24."
  type        = number
  default     = 24
  validation {
    condition     = contains([4, 6, 8, 12, 24], var.backup_every_hours)
    error_message = "4, 6, 8, 12 or 24."
  }
}

variable "backup_retention_days" {
  description = "Days a snapshot is kept."
  type        = number
  default     = 7
}
