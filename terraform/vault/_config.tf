terraform {
  required_version = ">= 1.5.0"
  required_providers {
    vault = {
      source  = "hashicorp/vault"
      version = "4.6.0"
    }
  }
  backend "kubernetes" {
    secret_suffix = "vault"
    config_path   = "../../outputs/kubeconfig.conf"
  }
}
