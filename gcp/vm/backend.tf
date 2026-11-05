# The Terraform state, in a Cloud Storage bucket of your project, so that a later update or terraform destroy finds the
# deployment from any Cloud Shell. The bucket and the folder are given to terraform init: see the README. To keep the
# state in a local file instead, delete this file before terraform init.
terraform {
  backend "gcs" {}
}
