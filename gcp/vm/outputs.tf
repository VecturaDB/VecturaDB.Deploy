output "url" {
  description = "Address for the clients. With internal access it answers only inside the VPC of the deployment."
  value       = var.access == "internal" ? "http://${google_compute_instance.vm.network_interface[0].network_ip}:8000" : "https://${local.host}"
}

output "public_ip" {
  description = "External IP of the VM; with your own domain name, its DNS A record points here."
  value       = google_compute_address.ip.address
}

output "private_ip" {
  value = google_compute_instance.vm.network_interface[0].network_ip
}

output "vm" {
  description = "Name of the VM, for a restore."
  value       = google_compute_instance.vm.name
}

output "zone" {
  value = var.zone
}

output "data_disk" {
  value = google_compute_disk.data.name
}

output "engine" {
  value = var.engine
}

output "image" {
  value = local.image
}

output "project_id" {
  description = "The project of the deployment, for restore.sh."
  value       = var.project_id
}
