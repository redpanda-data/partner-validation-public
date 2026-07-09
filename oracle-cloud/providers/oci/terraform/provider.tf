terraform {
  required_providers {
    oci = {
      source  = "oracle/oci"
      version = ">= 5.0"
    }
  }
}

# Auth via ~/.oci/config [DEFAULT] profile (API key)
provider "oci" {
  config_file_profile = "DEFAULT"
  region              = var.region
}
