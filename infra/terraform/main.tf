# Reference the existing Fabric capacity by display name; fail fast if it isn't Active
# before anything downstream tries to assign a workspace to it. Skipped when capacity_id
# is supplied directly (e.g., a trial capacity the calling identity can't read).
data "fabric_capacity" "this" {
  count        = var.capacity_id == null ? 1 : 0
  display_name = var.capacity_name

  lifecycle {
    postcondition {
      condition     = self.state == "Active"
      error_message = "Fabric capacity '${var.capacity_name}' is not in the Active state."
    }
  }
}

locals {
  capacity_id = var.capacity_id != null ? var.capacity_id : data.fabric_capacity.this[0].id
}

# Resolve each database's effective settings, applying environment defaults where a
# per-database value is unset. Keyed by the databases map key.
locals {
  databases = {
    for key, db in var.databases : key => {
      database_display_name  = coalesce(db.display_name, key)
      workspace_display_name = coalesce(db.workspace_display_name, "${coalesce(db.display_name, key)} [${var.environment}]")
      workspace_description  = "${var.environment} workspace for the ${coalesce(db.display_name, key)} database."
      collation              = coalesce(db.collation, var.default_collation)
      backup_retention_days  = db.backup_retention_days != null ? db.backup_retention_days : var.default_backup_retention_days

      reader_group_display_name = coalesce(db.reader_group_display_name, "Fabric ${coalesce(db.display_name, key)} Readers [${var.environment}]")

      enable_workspace_identity = db.enable_workspace_identity
      # Environment-wide operators apply to every workspace; per-database extras merge on top.
      # Operator keys are namespaced so a per-database entry can never silently collide.
      additional_role_assignments = merge(
        { for k, v in var.workspace_operators : "operator-${k}" => v },
        db.additional_role_assignments
      )
    }
  }
}

# One module instance per database — each is its own workspace + SQL database + roles.
module "environment" {
  source   = "./modules/fabric-sql-environment"
  for_each = local.databases

  capacity_id                    = local.capacity_id
  skip_capacity_state_validation = var.skip_capacity_state_validation
  workspace_display_name         = each.value.workspace_display_name
  workspace_description          = each.value.workspace_description
  sql_database_name              = each.value.database_display_name
  sql_database_collation         = each.value.collation
  backup_retention_days          = each.value.backup_retention_days
  additional_role_assignments    = each.value.additional_role_assignments
  enable_workspace_identity      = each.value.enable_workspace_identity
  reader_group_display_name      = each.value.reader_group_display_name
}
