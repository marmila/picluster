terraform {
  required_version = ">= 1.0.0"
  required_providers {
    vault = {
      source  = "hashicorp/vault"
      version = "5.10.1"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "3.1.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "3.8.1"
    }
  }
}
