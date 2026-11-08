output "project_id" {
  description = "Project ID."
  value       = local.project_id

  precondition {
    condition = !(
      var.project_type == "hub" && contains(var.tiers, "nonprod") && contains(var.tiers, "prod") &&
      (var.cicd_project_id == null || var.cicd_project_id == var.project_id)
    )
    error_message = "With both nonprod and prod tiers, cicd_project_id must be set and differ from every hub project ID (sections 2.2, 2.10.2)."
  }
}

output "number" {
  description = "Project number, as a string."
  value       = local.number
}

output "labels" {
  description = "The project's labels (read in supplied mode, set in create mode)."
  value       = local.actual_labels
}

output "supplied" {
  description = "true when the project is supplied (create_projects = false)."
  value       = local.supplied
}
