terraform {
  # 1.11: the API key is a write-only argument, kept out of the state.
  required_version = ">= 1.11"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 6.0, < 8.0"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
  zone    = var.zone
}
