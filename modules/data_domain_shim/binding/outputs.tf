# Output as the design section 2.3 `binding` table.

output "binding_names" {
  description = "Map of binding key to binding resource name."
  value       = { for k, b in terraform_data.binding : k => "${b.triggers_replace.domain_name}/bindings/${k}" }
}
