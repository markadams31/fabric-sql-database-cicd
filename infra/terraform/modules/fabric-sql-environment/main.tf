# One database's home: a workspace on the shared capacity, the SQL database item inside it,
# and its team role assignments. The root module instantiates this once per database (per
# environment) via for_each — one workspace per database.

resource "fabric_workspace" "this" {
  display_name                   = var.workspace_display_name
  description                    = var.workspace_description
  capacity_id                    = var.capacity_id
  skip_capacity_state_validation = var.skip_capacity_state_validation

  identity = var.enable_workspace_identity ? { type = "SystemAssigned" } : null
}

# An empty database. Schema is deployed by the SqlPackage pipeline, not Terraform —
# Terraform owns the item's existence, the pipeline owns its contents. Any change to
# `configuration` (collation especially) recreates the database, so it is set once here.
resource "fabric_sql_database" "this" {
  display_name = var.sql_database_name
  workspace_id = fabric_workspace.this.id

  configuration = {
    creation_mode         = "New"
    collation             = var.sql_database_collation
    backup_retention_days = var.backup_retention_days
  }
}

# Extra workspace access for team principals (groups, users, service principals). The
# identity that creates the workspace is granted Admin automatically, so it must NOT be
# listed here — re-assigning it collides with the implicit grant.
resource "fabric_workspace_role_assignment" "additional" {
  for_each = var.additional_role_assignments

  workspace_id = fabric_workspace.this.id
  role         = each.value.role

  principal = {
    id   = each.value.principal_id
    type = each.value.principal_type
  }
}

# A Microsoft Entra security group for read-only access to this database. Terraform creates
# the group and exposes its object ID; the SqlPackage pipeline creates a contained database
# user for it (by object ID — a service-principal deploy identity can't use FROM EXTERNAL
# PROVIDER in Fabric) and adds it to the app_reader role (SELECT on the app schema).
# Membership is managed in Entra, not here.
resource "azuread_group" "reader" {
  display_name     = var.reader_group_display_name
  security_enabled = true
}
