# The child module declares provider sources (not versions — those live in the root module)
# so Terraform maps each local name to the right namespace: "fabric" to microsoft/fabric
# rather than the default hashicorp/fabric, and "azuread" (used for the reader group).
terraform {
  required_providers {
    fabric = {
      source = "microsoft/fabric"
    }
    azuread = {
      source = "hashicorp/azuread"
    }
  }
}
