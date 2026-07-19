# The Fabric provider takes all authentication from the environment — no secrets in code.
#   CI (GitHub Actions OIDC):  FABRIC_USE_OIDC=true, FABRIC_CLIENT_ID, FABRIC_TENANT_ID
#   Local:                     FABRIC_USE_CLI=true   (after `az login`)
provider "fabric" {}

# The Microsoft Entra provider creates the per-database read-only security group. Auth comes
# from the environment, the same identity as the Fabric provider and the state backend:
#   CI (GitHub Actions OIDC):  ARM_USE_OIDC=true, ARM_CLIENT_ID, ARM_TENANT_ID
#   Local:                     az login  (Azure CLI auth, the default)
# Creating a group is a directory WRITE: the identity needs the Microsoft Graph application
# permission Group.Create (or the Entra "Groups Administrator" role) — more than the
# read-only directory access used elsewhere. See README.md prerequisites.
provider "azuread" {}
