locals {
  suffix = random_string.suffix.result
  name   = "${var.project}-${var.environment}"

  tags = merge({
    project     = var.project
    environment = var.environment
    managed_by  = "terraform"
  }, var.tags)
}

resource "random_string" "suffix" {
  length  = 5
  upper   = false
  special = false
}

module "resource_group" {
  source  = "Azure/avm-res-resources-resourcegroup/azurerm"
  version = "0.5.0"

  name     = "rg-${local.name}"
  location = var.location
  tags     = local.tags
}

# ---------------------------------------------------------------------------
# Monitoring
# ---------------------------------------------------------------------------

module "log_analytics" {
  source  = "Azure/avm-res-operationalinsights-workspace/azurerm"
  version = "0.5.1"

  name                                      = "log-${local.name}-${local.suffix}"
  location                                  = var.location
  resource_group_name                       = module.resource_group.name
  log_analytics_workspace_sku               = "PerGB2018"
  log_analytics_workspace_retention_in_days = 30
  tags                                      = local.tags
}

module "app_insights" {
  source  = "Azure/avm-res-insights-component/azurerm"
  version = "0.5.0"

  name             = "appi-${local.name}-${local.suffix}"
  location         = var.location
  parent_id        = module.resource_group.resource_id
  workspace_id     = module.log_analytics.resource_id
  application_type = "web"
  tags             = local.tags
}

# ---------------------------------------------------------------------------
# Backend: Azure Functions (Flex Consumption, Node.js)
# ---------------------------------------------------------------------------

module "storage" {
  source  = "Azure/avm-res-storage-storageaccount/azurerm"
  version = "0.11.0"

  name                     = substr("st${var.project}${var.environment}${local.suffix}", 0, 24)
  location                 = var.location
  parent_id                = module.resource_group.resource_id
  account_replication_type = "LRS"
  min_tls_version          = "TLS1_2"
  # Keys stay disabled (module default); the function app uses managed identity.
  shared_access_key_enabled = false
  # Flex Consumption without VNet integration reaches storage over the public endpoint.
  network_rules = null

  containers = {
    deployments = {
      name = "app-package"
    }
  }

  tags = local.tags
}

module "func_identity" {
  source  = "Azure/avm-res-managedidentity-userassignedidentity/azurerm"
  version = "0.6.0"

  name                = "id-func-${local.name}-${local.suffix}"
  location            = var.location
  resource_group_name = module.resource_group.name

  # Function host (AzureWebJobsStorage), deployment package and telemetry via managed identity.
  outbound_role_assignments = {
    storage_blob = {
      role_definition_id_or_name = "Storage Blob Data Owner"
      scope                      = module.storage.resource_id
    }
    storage_queue = {
      role_definition_id_or_name = "Storage Queue Data Contributor"
      scope                      = module.storage.resource_id
    }
    storage_table = {
      role_definition_id_or_name = "Storage Table Data Contributor"
      scope                      = module.storage.resource_id
    }
    monitoring = {
      role_definition_id_or_name = "Monitoring Metrics Publisher"
      scope                      = module.app_insights.resource_id
    }
  }

  tags = local.tags
}

module "func_plan" {
  source  = "Azure/avm-res-web-serverfarm/azurerm"
  version = "2.0.8"

  name                   = "asp-${local.name}-${local.suffix}"
  location               = var.location
  parent_id              = module.resource_group.resource_id
  os_type                = "Linux"
  sku_name               = "FC1"
  zone_balancing_enabled = false
  tags                   = local.tags
}

module "func" {
  source  = "Azure/avm-res-web-site/azurerm"
  version = "0.24.1"

  name                     = "func-${local.name}-${local.suffix}"
  location                 = var.location
  parent_id                = module.resource_group.resource_id
  service_plan_resource_id = module.func_plan.resource_id
  kind                     = "functionapp"
  os_type                  = "Linux"
  https_only               = true

  function_app_uses_fc1  = true
  fc1_runtime_name       = "node"
  fc1_runtime_version    = var.node_version
  maximum_instance_count = var.function_max_instance_count
  instance_memory_in_mb  = var.function_instance_memory_mb

  managed_identities = {
    user_assigned_resource_ids = [module.func_identity.resource_id]
  }

  # Deployment package storage (Flex Consumption).
  storage_container_type            = "blobContainer"
  storage_container_endpoint        = "https://${module.storage.fqdn["blob"]}/${module.storage.containers["deployments"].name}"
  storage_authentication_type       = "UserAssignedIdentity"
  storage_user_assigned_identity_id = module.func_identity.resource_id

  # Host storage (AzureWebJobsStorage__*) via the same identity.
  storage_account_name                     = module.storage.name
  storage_uses_managed_identity            = true
  storage_user_assigned_identity_client_id = module.func_identity.client_id

  application_insights_connection_string = module.app_insights.connection_string
  app_settings = {
    APPLICATIONINSIGHTS_AUTHENTICATION_STRING = "ClientId=${module.func_identity.client_id};Authorization=AAD"
  }

  site_config = {
    minimum_tls_version = "1.2"
  }

  tags = local.tags

  # Role assignments must exist before the app starts pulling its package.
  depends_on = [module.func_identity]
}

# ---------------------------------------------------------------------------
# Frontend: Static Web App (React/Vite) with the Function App linked as /api
# ---------------------------------------------------------------------------

module "web" {
  source  = "Azure/avm-res-web-staticsite/azurerm"
  version = "0.6.2"

  name                = "stapp-${local.name}-${local.suffix}"
  location            = var.static_web_app_location
  resource_group_name = module.resource_group.name

  # Standard tier is required to link a bring-your-own Function App backend.
  sku_tier = "Standard"
  sku_size = "Standard"

  tags = local.tags
}

# No AVM module covers SWA linked backends, so this one stays a plain resource.
# Routes https://<swa>/api/* to the Function App (functions use the /api prefix by default).
resource "azurerm_static_web_app_function_app_registration" "api" {
  static_web_app_id = module.web.resource_id
  function_app_id   = module.func.resource_id
}

# ---------------------------------------------------------------------------
# CI/CD: identity GitHub Actions logs in as (OIDC, no secrets).
# Least privilege: deploy code to the Function App only.
# ---------------------------------------------------------------------------

module "cicd_identity" {
  source  = "Azure/avm-res-managedidentity-userassignedidentity/azurerm"
  version = "0.6.0"

  name                = "id-cicd-${local.name}-${local.suffix}"
  location            = var.location
  resource_group_name = module.resource_group.name

  federated_identity_credentials = {
    github = {
      name     = "github-${var.github_environment}"
      issuer   = "https://token.actions.githubusercontent.com"
      audience = ["api://AzureADTokenExchange"]
      subject  = "${var.github_oidc_subject_prefix}:environment:${var.github_environment}"
    }
  }

  outbound_role_assignments = {
    func_deploy = {
      role_definition_id_or_name = "Website Contributor"
      scope                      = module.func.resource_id
    }
    swa_deploy = {
      role_definition_id_or_name = azurerm_role_definition.swa_deploy.role_definition_resource_id
      scope                      = module.web.resource_id
    }
  }

  tags = local.tags
}

# The SWA deploy action only accepts a deployment token. Instead of storing it in
# GitHub, the pipeline logs in as the CI/CD identity and reads the token at runtime.
# No built-in role is that narrow, so this custom role allows only that.
resource "azurerm_role_definition" "swa_deploy" {
  name        = "SWA Deployment Token Reader (${local.name}-${local.suffix})"
  scope       = module.resource_group.resource_id
  description = "Read a Static Web App and list its deployment token."

  permissions {
    actions = [
      "Microsoft.Web/staticSites/read",
      "Microsoft.Web/staticSites/listSecrets/action",
    ]
  }

  assignable_scopes = [module.resource_group.resource_id]
}
