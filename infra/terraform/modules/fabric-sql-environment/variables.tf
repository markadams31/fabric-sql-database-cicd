variable "capacity_id" {
  type        = string
  description = "ID of the Fabric capacity the workspace is assigned to."
}

variable "skip_capacity_state_validation" {
  type        = bool
  description = "Skip the provider's capacity state validation when creating the workspace (for callers that can't read the capacity)."
  default     = false
}

variable "workspace_display_name" {
  type        = string
  description = "Display name of the Fabric workspace."
}

variable "workspace_description" {
  type        = string
  description = "Description of the Fabric workspace."
  default     = ""
}

variable "sql_database_name" {
  type        = string
  description = "Display name of the SQL database item."
}

variable "sql_database_collation" {
  type        = string
  description = "Database collation. Set at creation and immutable thereafter."
  default     = "SQL_Latin1_General_CP1_CI_AS"
}

variable "backup_retention_days" {
  type        = number
  description = "Point-in-time-restore retention window, in days (1-35)."
  default     = 7

  validation {
    condition     = var.backup_retention_days >= 1 && var.backup_retention_days <= 35
    error_message = "backup_retention_days must be between 1 and 35."
  }
}

variable "additional_role_assignments" {
  type = map(object({
    principal_id   = string
    principal_type = string
    role           = string
  }))
  description = <<-EOT
    Workspace role assignments for team principals, keyed by a stable name. Do NOT list
    the deploy identity: whoever creates the workspace becomes Admin automatically, and
    re-assigning it collides. principal_id is the Entra object (principal) ID — for a
    managed identity this is its principal ID, not its client ID.
  EOT
  default     = {}

  validation {
    condition = alltrue([
      for a in values(var.additional_role_assignments) :
      contains(["Admin", "Member", "Contributor", "Viewer"], a.role)
    ])
    error_message = "role must be one of Admin, Member, Contributor, Viewer."
  }

  validation {
    condition = alltrue([
      for a in values(var.additional_role_assignments) :
      contains(["Group", "User", "ServicePrincipal", "ServicePrincipalProfile"], a.principal_type)
    ])
    error_message = "principal_type must be one of Group, User, ServicePrincipal, ServicePrincipalProfile."
  }
}

variable "enable_workspace_identity" {
  type        = bool
  description = "Provision a system-assigned workspace identity."
  default     = false
}

variable "reader_group_display_name" {
  type        = string
  description = "Display name of the Microsoft Entra security group granted read-only access to this database. Terraform creates the group; the deploy pipeline creates a matching contained database user and adds it to the app_reader role (SELECT on the app schema)."
}
