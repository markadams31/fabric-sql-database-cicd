terraform {
  required_version = ">= 1.9"

  required_providers {
    fabric = {
      source  = "microsoft/fabric"
      version = "~> 1.12"
    }
    azuread = {
      source  = "hashicorp/azuread"
      version = "~> 3.0"
    }
  }

  # Remote state in Azure Storage. This is a partial configuration: the storage account,
  # container, state key, and tenant come from environments/<env>.backend.hcl at init:
  #   terraform init -backend-config=environments/<env>.backend.hcl
  #
  # use_azuread_auth is set here (invariant across environments): the backend authenticates
  # to the blob data plane with a Microsoft Entra token, so it needs only Storage Blob Data
  # Contributor on the container and never touches ARM in the state subscription — which is
  # what lets the state account live in a different subscription than everything else.
  backend "azurerm" {
    use_azuread_auth = true
  }
}
