# Outputs exactly as the design section 2.3 `domain` table.

output "name" {
  description = "The domain's resource name."
  value       = try(jsondecode(data.http.domain.response_body).name, null)
}

output "policy_member" {
  description = "policyMember: the principal that bound resources must grant (ddaDomainDelegate, section 2.3.1)."
  value       = try(jsondecode(data.http.domain.response_body).policyMember, null)
}
