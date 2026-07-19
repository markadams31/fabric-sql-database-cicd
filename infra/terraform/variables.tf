variable "environment" {
  type        = string
  description = "Environment label for this state — e.g. dev, test, prod. Any lowercase name works; it labels workspaces and the reader group and selects the tfvars/backend files."

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]*$", var.environment))
    error_message = "environment must be lowercase letters, digits, or hyphens (e.g. dev, test, prod, staging)."
  }
}

variable "capacity_name" {
  type        = string
  description = "Display name of an existing Fabric capacity to look up and assign the workspaces to. Provide this OR capacity_id."
  default     = null
}

variable "capacity_id" {
  type        = string
  description = "ID of an existing Fabric capacity, used directly without a lookup. Provide this OR capacity_name. Use this when the capacity isn't resolvable by the calling identity (e.g., a trial capacity seen through a guest identity)."
  default     = null

  validation {
    condition     = (var.capacity_id == null) != (var.capacity_name == null)
    error_message = "Set exactly one of capacity_id or capacity_name."
  }
}

variable "skip_capacity_state_validation" {
  type        = bool
  description = "Skip the provider's capacity state validation when creating workspaces. Set true when the calling identity can't read the capacity (e.g., a guest identity using a trial capacity)."
  default     = false
}

variable "default_collation" {
  type        = string
  description = "Collation for databases that don't set their own. Set at creation and immutable thereafter."
  default     = "SQL_Latin1_General_CP1_CI_AS"
}

variable "default_backup_retention_days" {
  type        = number
  description = "Point-in-time-restore retention (1-35 days) for databases that don't set their own."
  default     = 7

  validation {
    condition     = var.default_backup_retention_days >= 1 && var.default_backup_retention_days <= 35
    error_message = "default_backup_retention_days must be between 1 and 35."
  }
}

variable "workspace_operators" {
  type = map(object({
    principal_id   = string
    principal_type = string
    role           = string
  }))
  description = <<-EOT
    Principals granted a workspace role on EVERY database's workspace in this environment —
    the human/operator access. When the deploy identity provisions the estate (the CI path),
    it is the only principal on each new workspace; without an entry here no person can even
    see the workspaces, let alone perform the manual item-share step. Grant a security group,
    not individuals, and manage people via group membership. principal_id is the Entra object
    ID. Do NOT list the deploy identity (it is granted Admin implicitly as creator).
    Per-database extras still belong in each database's additional_role_assignments.
  EOT
  default     = {}

  validation {
    condition     = alltrue([for a in values(var.workspace_operators) : contains(["Admin", "Member", "Contributor", "Viewer"], a.role)])
    error_message = "Each operator role must be one of Admin, Member, Contributor, Viewer."
  }

  validation {
    condition     = alltrue([for a in values(var.workspace_operators) : contains(["Group", "User", "ServicePrincipal", "ServicePrincipalProfile"], a.principal_type)])
    error_message = "Each operator principal_type must be one of Group, User, ServicePrincipal, ServicePrincipalProfile."
  }
}

variable "databases" {
  type = map(object({
    display_name              = optional(string)
    workspace_display_name    = optional(string)
    collation                 = optional(string)
    backup_retention_days     = optional(number)
    enable_workspace_identity = optional(bool, false)
    reader_group_display_name = optional(string)
    additional_role_assignments = optional(map(object({
      principal_id   = string
      principal_type = string
      role           = string
    })), {})
  }))
  description = <<-EOT
    Databases to provision in this environment, keyed by a short stable name. Each database
    gets its OWN Fabric workspace on the shared capacity — one workspace per database.
    Add a database by adding a map entry (and a matching databases/<key>/ SQL project).

    Per-database fields fall back to environment defaults when unset:
      display_name              -> the map key
      workspace_display_name    -> "<display_name> [<environment>]"
      collation                 -> var.default_collation
      backup_retention_days     -> var.default_backup_retention_days
      reader_group_display_name -> "Fabric <display_name> Readers [<environment>]"

    Do NOT list the deploy identity in additional_role_assignments — it is granted Admin
    automatically as the workspace creator. principal_id is the Entra object (principal) ID.
  EOT
  default     = {}

  validation {
    condition = alltrue([
      for db in values(var.databases) :
      db.backup_retention_days == null || try(db.backup_retention_days >= 1 && db.backup_retention_days <= 35, false)
    ])
    error_message = "Each database's backup_retention_days, when set, must be between 1 and 35."
  }

  validation {
    condition = alltrue([
      for db in values(var.databases) : alltrue([
        for a in values(db.additional_role_assignments) :
        contains(["Admin", "Member", "Contributor", "Viewer"], a.role)
      ])
    ])
    error_message = "Each role must be one of Admin, Member, Contributor, Viewer."
  }

  validation {
    condition = alltrue([
      for db in values(var.databases) : alltrue([
        for a in values(db.additional_role_assignments) :
        contains(["Group", "User", "ServicePrincipal", "ServicePrincipalProfile"], a.principal_type)
      ])
    ])
    error_message = "Each principal_type must be one of Group, User, ServicePrincipal, ServicePrincipalProfile."
  }
}
