# Chroma or VecturaDB on one Compute Engine VM with Docker, the data on a disk of its own, HTTPS with Caddy.
# There is no SSH: the agent of the VM (scripts/agent.sh) configures the server from the metadata key chroma-config and
# reports the outcome in the guest attributes, which terraform apply waits for (scripts/wait-configured.sh).

locals {
  labels   = { chroma-deployment = var.name }
  image    = var.engine == "vecturadb" ? var.vecturadb_image : var.chroma_image
  with_key = var.engine == "vecturadb" && var.api_key != ""
  host     = var.domain_name != "" ? var.domain_name : google_compute_address.ip.address
  config = jsonencode({
    engine         = var.engine
    image          = local.image
    access         = var.access
    host           = local.host
    allowed_ips    = join(" ", var.allowed_ip_ranges)
    acme_email     = var.acme_email
    api_key_secret = local.with_key ? google_secret_manager_secret.api_key[0].id : ""
    # A new key is a new version of the secret: the server restarts with it.
    api_key_version = local.with_key ? google_secret_manager_secret_version.api_key[0].name : ""
  })
  config_hash = substr(sha256(local.config), 0, 16)
}

resource "google_project_service" "compute" {
  service            = "compute.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "secretmanager" {
  count              = local.with_key ? 1 : 0
  service            = "secretmanager.googleapis.com"
  disable_on_destroy = false
}

resource "google_compute_network" "net" {
  name                    = "${var.name}-net"
  auto_create_subnetworks = false
  depends_on              = [google_project_service.compute]
}

resource "google_compute_subnetwork" "subnet" {
  name          = "${var.name}-subnet"
  network       = google_compute_network.net.id
  region        = var.region
  ip_cidr_range = "10.42.0.0/24"
}

# HTTPS from the allowed ranges, or from anywhere with public access.
resource "google_compute_firewall" "https" {
  count         = var.access == "internal" ? 0 : 1
  name          = "${var.name}-https"
  network       = google_compute_network.net.id
  source_ranges = var.access == "public" ? ["0.0.0.0/0"] : var.allowed_ip_ranges
  target_tags   = [var.name]
  allow {
    protocol = "tcp"
    ports    = ["443"]
  }
}

# Port 80 is open only for the HTTP-01 challenge of the certificate: Caddy answers nothing else on it.
resource "google_compute_firewall" "acme" {
  count         = var.access == "internal" ? 0 : 1
  name          = "${var.name}-acme"
  network       = google_compute_network.net.id
  source_ranges = ["0.0.0.0/0"]
  target_tags   = [var.name]
  allow {
    protocol = "tcp"
    ports    = ["80"]
  }
}

resource "google_compute_firewall" "internal" {
  count         = var.access == "internal" ? 1 : 0
  name          = "${var.name}-internal"
  network       = google_compute_network.net.id
  source_ranges = ["10.42.0.0/24"]
  target_tags   = [var.name]
  allow {
    protocol = "tcp"
    ports    = ["8000"]
  }
}

# The address for HTTPS, and the way out to the package and image registries, also with internal access.
resource "google_compute_address" "ip" {
  name       = "${var.name}-ip"
  region     = var.region
  labels     = local.labels
  depends_on = [google_project_service.compute]
}

resource "google_compute_disk" "data" {
  name       = "${var.name}-data"
  type       = "pd-balanced"
  zone       = var.zone
  size       = var.data_disk_size_gb
  labels     = merge(local.labels, { chroma-backup = var.name })
  depends_on = [google_project_service.compute]
}

# Snapshots of the data disk. They are not part of the deployment: terraform destroy leaves them, see the README.
resource "google_compute_resource_policy" "backup" {
  count  = var.backup == "snapshots" ? 1 : 0
  name   = "${var.name}-backup"
  region = var.region
  snapshot_schedule_policy {
    schedule {
      dynamic "daily_schedule" {
        for_each = var.backup_every_hours == 24 ? [1] : []
        content {
          days_in_cycle = 1
          start_time    = "02:00"
        }
      }
      dynamic "hourly_schedule" {
        for_each = var.backup_every_hours == 24 ? [] : [1]
        content {
          hours_in_cycle = var.backup_every_hours
          start_time     = "02:00"
        }
      }
    }
    retention_policy {
      max_retention_days    = var.backup_retention_days
      on_source_disk_delete = "KEEP_AUTO_SNAPSHOTS"
    }
    snapshot_properties {
      labels            = { chroma-backup = var.name }
      storage_locations = [var.region]
    }
  }
  depends_on = [google_project_service.compute]
}

resource "google_compute_disk_resource_policy_attachment" "backup" {
  count = var.backup == "snapshots" ? 1 : 0
  name  = google_compute_resource_policy.backup[0].name
  disk  = google_compute_disk.data.name
  zone  = var.zone
}

# The VM reads only the secret with the API key: no other role.
resource "google_service_account" "vm" {
  account_id   = "${var.name}-vm"
  display_name = "VM of ${var.name}"
}

resource "google_secret_manager_secret" "api_key" {
  count     = local.with_key ? 1 : 0
  secret_id = "${var.name}-api-key"
  labels    = local.labels
  replication {
    auto {}
  }
  depends_on = [google_project_service.secretmanager]
}

resource "google_secret_manager_secret_version" "api_key" {
  count       = local.with_key ? 1 : 0
  secret      = google_secret_manager_secret.api_key[0].id
  secret_data = var.api_key
}

resource "google_secret_manager_secret_iam_member" "vm" {
  count     = local.with_key ? 1 : 0
  secret_id = google_secret_manager_secret.api_key[0].id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.vm.email}"
}

resource "google_compute_instance" "vm" {
  name                      = var.name
  zone                      = var.zone
  machine_type              = var.machine_type
  tags                      = [var.name]
  labels                    = local.labels
  allow_stopping_for_update = true

  boot_disk {
    initialize_params {
      image  = "ubuntu-os-cloud/ubuntu-2404-lts-amd64"
      size   = 10
      type   = "pd-balanced"
      labels = local.labels
    }
  }

  # Attached with the VM and detached by its deletion: never detached while it is mounted.
  attached_disk {
    source      = google_compute_disk.data.id
    device_name = "chroma-data"
  }

  network_interface {
    subnetwork = google_compute_subnetwork.subnet.id
    access_config {
      nat_ip = google_compute_address.ip.address
    }
  }

  service_account {
    email  = google_service_account.vm.email
    scopes = ["cloud-platform"]
  }

  metadata = {
    enable-guest-attributes = "TRUE"
    startup-script          = file("${path.module}/scripts/first-boot.sh")
    chroma-agent            = file("${path.module}/scripts/agent.sh")
    chroma-configure        = file("${path.module}/scripts/configure.sh")
    chroma-restore-script   = file("${path.module}/scripts/restore.sh")
    chroma-config           = local.config
  }

  lifecycle {
    # The image of the operating system is the latest Ubuntu 24.04 at the creation: an apply never replaces the VM.
    # chroma-restore is set by restore.sh, not by the template.
    ignore_changes = [boot_disk[0].initialize_params[0].image, metadata["chroma-restore"]]
    precondition {
      condition     = var.access != "public" || local.with_key
      error_message = "Public access needs engine = \"vecturadb\" and an api_key: Chroma 1.5.9 has no API keys."
    }
    precondition {
      condition     = var.access != "allowed-ips" || length(var.allowed_ip_ranges) > 0
      error_message = "Access allowed-ips needs at least one range in allowed_ip_ranges."
    }
    precondition {
      condition     = !local.with_key || length(var.api_key) >= 16
      error_message = "The api_key needs at least 16 characters."
    }
  }

  depends_on = [google_secret_manager_secret_iam_member.vm]
}

# terraform apply ends only when the agent of the VM reports this configuration: the server answers and, with HTTPS,
# Caddy holds the certificate.
resource "terraform_data" "configured" {
  triggers_replace = [google_compute_instance.vm.instance_id, local.config_hash]
  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    command     = "bash '${path.module}/scripts/wait-configured.sh' '${var.name}' '${var.zone}' '${var.project_id}' '${local.config_hash}'"
  }
}
