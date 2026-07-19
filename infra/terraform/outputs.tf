output "environment" {
  description = "Environment label for this state."
  value       = var.environment
}

output "databases" {
  description = "Per-database provisioning results, keyed by the databases map key. Feed sql_server_fqdn and sql_database_name into the matching GitHub environment for the deploy pipeline."
  value = {
    for key, mod in module.environment : key => {
      workspace_id              = mod.workspace_id
      sql_database_id           = mod.sql_database_id
      sql_server_fqdn           = mod.sql_server_fqdn
      sql_database_name         = mod.sql_database_name
      reader_group_object_id    = mod.reader_group_object_id
      reader_group_display_name = mod.reader_group_display_name
    }
  }
}

output "sql_connection_strings" {
  description = "Per-database connection strings (Microsoft Entra authentication), keyed by the databases map key."
  value       = { for key, mod in module.environment : key => mod.sql_connection_string }
  sensitive   = true
}
