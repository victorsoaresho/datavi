# infra/bootstrap/main.tf
#
# Cria o bucket que guarda o state remoto dos demais ambientes.
# Usa state LOCAL de propósito: o bucket ainda não existe quando este código roda.
terraform {
  required_version = ">= 1.11"
  required_providers {
    mgc = {
      source  = "MagaluCloud/mgc"
      version = "~> 0.56.0"
    }
  }
}

provider "mgc" {
  api_key         = var.mgc_api_key
  key_pair_id     = var.mgc_key_pair_id
  key_pair_secret = var.mgc_key_pair_secret
  region          = "br-se1"
}

variable "mgc_api_key" {
  description = "API Key do ID Magalu (autenticação geral do provider)"
  type        = string
  sensitive   = true
}

variable "mgc_key_pair_id" {
  description = "Key Pair ID da API key, usado pelo Object Storage"
  type        = string
  sensitive   = true
}

variable "mgc_key_pair_secret" {
  description = "Key Pair Secret da API key, usado pelo Object Storage"
  type        = string
  sensitive   = true
}

resource "mgc_object_storage_buckets" "tfstate" {
  bucket     = "dataplat-state"
  versioning = true

  lifecycle {
    prevent_destroy = true
  }
}

output "state_bucket" {
  value = mgc_object_storage_buckets.tfstate.bucket
}

# Revela o endpoint S3 da região, necessário para o backend dos outros ambientes
output "state_bucket_url" {
  value = mgc_object_storage_buckets.tfstate.url
}
