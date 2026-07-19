output "workspace_id" {
  description = "ID of the Fabric workspace."
  value       = fabric_workspace.this.id
}

output "sql_database_id" {
  description = "ID of the SQL database item."
  value       = fabric_sql_database.this.id
}

output "sql_server_fqdn" {
  description = "Fully qualified server name for the SQL connection endpoint."
  value       = fabric_sql_database.this.properties.server_fqdn
}

output "sql_database_name" {
  description = "Database name on the SQL endpoint."
  value       = fabric_sql_database.this.properties.database_name
}

output "sql_connection_string" {
  description = "Connection string for the database (Microsoft Entra authentication)."
  value       = fabric_sql_database.this.properties.connection_string
  sensitive   = true
}

output "reader_group_object_id" {
  description = "Object ID of the read-only Entra security group, used as the SID for the contained database user: CREATE USER ... WITH SID = <id>, TYPE = X."
  value       = azuread_group.reader.object_id
}

output "reader_group_display_name" {
  description = "Display name of the read-only Entra security group — also the contained database user's name."
  value       = azuread_group.reader.display_name
}
