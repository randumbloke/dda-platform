/**
 Organisation custom roles (§1.5.2, §2.3.1, §2.4.7) and organisation policies (§2.1.1).

 Custom roles are always created. Permission names: VERIFY IN BUILD (VA-99); Beta permissions in
 custom roles: VERIFY IN BUILD (VA-87).

 Organisation policies: manage_org_policies = false in phase 1 (OD-1), so every policy resource
 below has count = 0 and the owner sets the constraints at project scope instead (change task
 2.4). The resources stay declared so that the .tf files are the same in every mode (§6.13.5).
 */

locals {
  custom_roles = merge(
    {
      ddaMetadataSteward = {
        title       = "DDA metadata steward"
        description = "Curation without aspect type, entry type or system quality aspect writes (§1.5.2)."
        permissions = [
          "dataplex.entries.get",
          "dataplex.entries.list",
          "dataplex.entries.update",
          "dataplex.entryGroups.get",
          "dataplex.entryGroups.list",
          "dataplex.entryGroups.useOverviewAspect",
          "dataplex.entryGroups.useDescriptionsAspect",
          "dataplex.entryGroups.useDefinitionEntryLink",
          "dataplex.entryGroups.useSynonymEntryLink",
          "dataplex.entryGroups.useRelatedEntryLink",
          "dataplex.entryLinks.create",
          "dataplex.entryLinks.get",
          "dataplex.entryLinks.update",
          "dataplex.entryLinks.delete",
          "dataplex.glossaries.get",
          "dataplex.glossaries.list",
          "dataplex.glossaryTerms.get",
          "dataplex.glossaryTerms.list",
          "dataplex.glossaryTerms.use",
          "dataplex.projects.search",
          "dataplex.changeRequests.get",
          "dataplex.changeRequests.list",
          # Domain-scoped; VERIFY IN BUILD (VA-48).
          "dataplex.dataDomains.lookupEntry",
          "dataplex.dataDomains.modifyEntry",
        ]
      }
      ddaProductApprover = {
        title       = "DDA product approver"
        description = "Approve data product access requests without product update or delete (§1.5.2; VA-43)."
        permissions = [
          "dataplex.dataProducts.get",
          "dataplex.dataProducts.approve",
          "dataplex.changeRequests.get",
          "dataplex.changeRequests.list",
        ]
      }
      ddaDomainDelegate = {
        title       = "DDA domain delegate"
        description = "Granted to a domain's policyMember on a dataset or product so it can be bound; no data access (§2.3.1). VERIFY IN BUILD (VA-49)."
        permissions = [
          "bigquery.datasets.get",
          "bigquery.datasets.getIamPolicy",
          "bigquery.datasets.setIamPolicy",
          "dataplex.dataProducts.get",
          "dataplex.dataProducts.getIamPolicy",
          "dataplex.dataProducts.setIamPolicy",
        ]
      }
      ddaDomainBinder = {
        title       = "DDA domain binder"
        description = "Bind resources to one data domain without dataDomains.update (§6.7.1). Not granted when single_deployer = true. VERIFY IN BUILD (VA-87)."
        permissions = [
          "dataplex.dataDomainBindings.create",
          "dataplex.dataDomainBindings.delete",
          "dataplex.dataDomainBindings.get",
          "dataplex.dataDomainBindings.list",
          "dataplex.dataDomains.get",
        ]
      }
      ddaAspectWriter = {
        title       = "DDA aspect writer"
        description = "Write custom aspects whose type grants aspectTypes.use; no system aspects (§2.4.7). VERIFY IN BUILD (VA-76)."
        permissions = [
          "dataplex.entries.get",
          "dataplex.entries.update",
          "dataplex.entryGroups.get",
        ]
      }
      ddaPolicyTagIamAdmin = {
        title       = "DDA policy tag IAM admin"
        description = "Policy tag IAM without taxonomy changes (§2.4.7)."
        permissions = [
          "datacatalog.taxonomies.get",
          "datacatalog.categories.getIamPolicy",
          "datacatalog.categories.setIamPolicy",
        ]
      }
      ddaPipelineCatalogWriter = {
        title       = "DDA pipeline catalog writer"
        description = "Table contacts and product refresh-cadence aspects (§2.4.7)."
        permissions = [
          "dataplex.entries.get",
          "dataplex.entries.update",
          "dataplex.entryGroups.get",
          "dataplex.entryGroups.useContactsAspect",
          "dataplex.entryGroups.useRefreshCadenceAspect",
        ]
      }
      ddaAccessRequestHandler = {
        title       = "DDA access request handler"
        description = "Access request gate: read and reject requests (§2.4.7; VA-67)."
        permissions = [
          "dataplex.dataProducts.get",
          "dataplex.dataProducts.approve",
          "dataplex.changeRequests.get",
          "dataplex.changeRequests.list",
        ]
      }
      ddaSubscriptionAdmin = {
        title       = "DDA subscription admin"
        description = "Manage subscriptions on hub topics without topic update or delete (§2.4.7). VERIFY IN BUILD (VA-99)."
        permissions = [
          "pubsub.subscriptions.create",
          "pubsub.subscriptions.delete",
          "pubsub.subscriptions.get",
          "pubsub.subscriptions.list",
          "pubsub.subscriptions.update",
          "pubsub.subscriptions.getIamPolicy",
          "pubsub.subscriptions.setIamPolicy",
          "pubsub.topics.attachSubscription",
          "pubsub.topics.get",
        ]
      }
    },
    # Created only when the policy_tags component is on (P6-36). VERIFY IN BUILD (VA-50).
    var.policy_tags_enabled ? {
      ddaPolicyTagApplier = {
        title       = "DDA policy tag applier"
        description = "Attach policy tags without data access (§2.4.7)."
        permissions = [
          "bigquery.tables.get",
          "bigquery.tables.update",
          "bigquery.tables.setCategory",
          "datacatalog.taxonomies.get",
        ]
      }
    } : {},
  )
}

resource "google_organization_iam_custom_role" "role" {
  for_each = local.custom_roles

  org_id      = var.organization_id
  role_id     = each.key
  title       = each.value.title
  description = each.value.description
  permissions = each.value.permissions
  stage       = "GA"
}

# --------------------------------------------------------------------------------------------
# Organisation policies (§2.1.1): count = 0 while manage_org_policies = false (OD-1).
# --------------------------------------------------------------------------------------------

locals {
  org_parent      = "organizations/${var.organization_id}"
  org_policy_on   = var.manage_org_policies ? 1 : 0
  enforced_policy = ["iam.disableServiceAccountKeyCreation", "storage.uniformBucketLevelAccess", "storage.publicAccessPrevention"]
}

resource "google_org_policy_policy" "resource_locations" {
  count = local.org_policy_on

  name   = "${local.org_parent}/policies/gcp.resourceLocations"
  parent = local.org_parent

  spec {
    rules {
      values {
        allowed_values = [for r in var.regions : "in:${r}-locations"]
      }
    }
  }
}

resource "google_org_policy_policy" "allowed_policy_member_domains" {
  count = local.org_policy_on

  name   = "${local.org_parent}/policies/iam.allowedPolicyMemberDomains"
  parent = local.org_parent

  spec {
    rules {
      values {
        allowed_values = [var.customer_id]
      }
    }
  }
}

resource "google_org_policy_policy" "enforced" {
  count = var.manage_org_policies ? length(local.enforced_policy) : 0

  name   = "${local.org_parent}/policies/${local.enforced_policy[count.index]}"
  parent = local.org_parent

  spec {
    rules {
      enforce = "TRUE"
    }
  }
}

# run.allowedIngress on the hub projects only. VERIFY IN BUILD (VA-52).
resource "google_org_policy_policy" "run_allowed_ingress" {
  count = var.manage_org_policies ? length(local.hub_projects) : 0

  name   = "projects/${local.hub_projects[count.index]}/policies/run.allowedIngress"
  parent = "projects/${local.hub_projects[count.index]}"

  spec {
    rules {
      values {
        allowed_values = ["is:internal"]
      }
    }
  }
}
