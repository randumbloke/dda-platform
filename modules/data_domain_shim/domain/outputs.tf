# Outputs exactly as the design section 2.3 `domain` table.

output "name" {
  description = "The domain's resource name."
  value       = try(jsondecode(data.http.domain.response_body).name, null)
}

# policyMember is an object (GoogleIamV1ResourcePolicyMember); the output is its
# iamPolicyNamePrincipal string (principal://...).
# VERIFY IN BUILD (VA-12): that this is the form IAM bindings accept (fallback:
# iamPolicyUidPrincipal).
output "policy_member" {
  description = "policyMember (as its iamPolicyNamePrincipal string): the principal that bound resources must grant (ddaDomainDelegate, section 2.3.1)."
  value       = try(jsondecode(data.http.domain.response_body).policyMember.iamPolicyNamePrincipal, null)
}
