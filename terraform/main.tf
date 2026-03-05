terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "=4.45.1"
    }
    random = {
      source  = "hashicorp/random"
      version = "=3.1.0"
    }
    azapi = {
      source = "azure/azapi"
      version = "=2.3.0"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.13"
    }
    azuread = {
      source  = "hashicorp/azuread"
      version = "~> 2.53.1"
    }
  }
}

provider "azurerm" {
  features {
    resource_group {
      prevent_deletion_if_contains_resources = false
    }
  }

  subscription_id = var.subscription_id
}

resource "random_string" "unique" {
  length  = 8
  special = false
  upper   = false
}

data "azurerm_client_config" "current" {}

data "azurerm_log_analytics_workspace" "default" {
  name                = "DefaultWorkspace-${data.azurerm_client_config.current.subscription_id}-${local.loc_short}"
  resource_group_name = "DefaultResourceGroup-${local.loc_short}"
} 

resource "azurerm_resource_group" "rg" {
  name     = "rg-${local.gh_repo}-${random_string.unique.result}-${local.loc_for_naming}"
  location = var.location
  tags = local.tags
}

resource "azurerm_virtual_network" "default" {
  name                = "vnet-${local.func_name}-${local.loc_for_naming}"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  address_space       = ["172.21.0.0/16"]

  tags = local.tags
}

resource "azurerm_subnet" "default" {
  name                 = "default-subnet-${local.loc_for_naming}"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.default.name
  address_prefixes     = ["172.21.0.0/24"]
}

resource "azurerm_subnet" "cluster" {
  name                 = "cluster-subnet-${local.loc_for_naming}"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.default.name
  address_prefixes     = ["172.21.1.0/24"]

  delegation {
    name = "Microsoft.App/environments"
    service_delegation {
      name    = "Microsoft.App/environments"
      actions = ["Microsoft.Network/virtualNetworks/subnets/join/action"]
    }
  
  }
}


resource "azurerm_subnet" "pe" {
  name                 = "pe-subnet-${local.loc_for_naming}"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.default.name
  address_prefixes     = ["172.21.2.0/24"]
}

resource "azurerm_key_vault" "kv" {
  name                       = "kv-${local.func_name}"
  location                   = azurerm_resource_group.rg.location
  resource_group_name        = azurerm_resource_group.rg.name
  tenant_id                  = data.azurerm_client_config.current.tenant_id
  sku_name                   = "standard"
  soft_delete_retention_days = 7
  purge_protection_enabled   = false
  rbac_authorization_enabled = true

}

resource "azurerm_role_assignment" "kv_officer" {
  scope                            = azurerm_key_vault.kv.id
  role_definition_name             = "Key Vault Secrets Officer"
  principal_id                     = data.azurerm_client_config.current.object_id
}

resource "azurerm_role_assignment" "kv_cert_officer" {
  scope                            = azurerm_key_vault.kv.id
  role_definition_name             = "Key Vault Certificates Officer"
  principal_id                     = data.azurerm_client_config.current.object_id
}

resource "azurerm_application_insights" "app" {
  name                = "${local.func_name}-insights"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  application_type    = "other"
  workspace_id        = data.azurerm_log_analytics_workspace.default.id
}

resource "azurerm_user_assigned_identity" "this" {
  location            = azurerm_resource_group.rg.location
  name                = "uai-${local.func_name}"
  resource_group_name = azurerm_resource_group.rg.name
}

resource "azurerm_role_assignment" "containerapptokv" {
  scope                = azurerm_key_vault.kv.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_user_assigned_identity.this.principal_id
}

resource "azurerm_role_assignment" "reader" {
  scope                = "/subscriptions/${data.azurerm_client_config.current.subscription_id}"
  role_definition_name = "Reader"
  principal_id         = azurerm_user_assigned_identity.this.principal_id
}

resource "azurerm_container_app_environment" "this" {
  name                       = "ace-${local.func_name}"
  location                   = azurerm_resource_group.rg.location
  resource_group_name        = azurerm_resource_group.rg.name
  log_analytics_workspace_id = data.azurerm_log_analytics_workspace.default.id

  infrastructure_subnet_id = azurerm_subnet.cluster.id

  workload_profile {
    name                  = "Consumption"
    workload_profile_type = "Consumption"
  }

  tags = local.tags
  lifecycle {
    ignore_changes = [
     infrastructure_resource_group_name,
     log_analytics_workspace_id
    ]
  }
}

resource "azurerm_container_app" "bot" {
  name                         = "aca-${local.func_name}"
  container_app_environment_id = azurerm_container_app_environment.this.id
  resource_group_name          = azurerm_resource_group.rg.name
  revision_mode                = "Single"
  workload_profile_name        = "Consumption"

  template {
    container {
      name   = "bot"
      image  = "ghcr.io/${var.gh_repo}:latest"
      cpu    = 0.5
      memory = "1Gi"

      env {
        name = "RUNNING_ON_AZURE"
        value = "1"
      }

      env {
        name = "TENANT_ID"
        value = data.azurerm_client_config.current.tenant_id
      }

      env {
        name = "CLIENT_ID"
        value = azurerm_user_assigned_identity.bot.client_id
      }
      env {
        name = "tenantId"
        value = data.azurerm_client_config.current.tenant_id
      }

      env {
        name = "clientId"
        value = azurerm_user_assigned_identity.bot.client_id
      }

      env {
        name = "AZURE_CLIENT_ID"
        value = azurerm_user_assigned_identity.this.client_id
      }

      env{
        name = "graph_connectionName"
        value = "graph"
      }

      # new for M365 Agent SDK
      env {
        name = "CONNECTIONS__SERVICE_CONNECTION__SETTINGS__TENANTID"
        value = data.azurerm_client_config.current.tenant_id
      }
      env {
        name = "CONNECTIONS__SERVICE_CONNECTION__SETTINGS__CLIENTID"
        value = azurerm_user_assigned_identity.bot.client_id
      }
      env {
        name = "CONNECTIONS__SERVICE_CONNECTION__SETTINGS__AUTHTYPE"
        value = "UserManagedIdentity"
      }
      
      env {
        name = "AGENTAPPLICATION__USERAUTHORIZATION__HANDLERS__GRAPH__SETTINGS__AZUREBOTOAUTHCONNECTIONNAME"
        value = "graph"
      }

    }
    http_scale_rule {
      name                = "http-1"
      concurrent_requests = "100"
    }
    min_replicas = 1
    max_replicas = 1
  }

  ingress {
    allow_insecure_connections = false
    external_enabled           = true
    target_port                = 3978
    transport                  = "auto"
    traffic_weight {
      latest_revision = true
      percentage      = 100
    }
  }

  identity {
    type = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.this.id, azurerm_user_assigned_identity.bot.id]
  }
  tags = local.tags

  lifecycle {
    ignore_changes = [ secret ]
  }
}

resource "azurerm_user_assigned_identity" "bot" {
  location            = azurerm_resource_group.rg.location
  name                = "uai-bot-${local.func_name}"
  resource_group_name = azurerm_resource_group.rg.name
}

resource "azurerm_bot_service_azure_bot" "teamsbot" {
  name                = "bot-${local.func_name}"
  resource_group_name = azurerm_resource_group.rg.name
  location            = "global"
  microsoft_app_id    = azurerm_user_assigned_identity.bot.client_id
  sku                 = "F0"
  endpoint            = "https://${azurerm_container_app.bot.ingress[0].fqdn}/api/messages"
  microsoft_app_msi_id = azurerm_user_assigned_identity.bot.id
  microsoft_app_tenant_id = data.azurerm_client_config.current.tenant_id
  microsoft_app_type  = "UserAssignedMSI"
  tags = local.tags
}

resource "azurerm_bot_channel_ms_teams" "teams" {
  bot_name            = azurerm_bot_service_azure_bot.teamsbot.name
  location            = azurerm_bot_service_azure_bot.teamsbot.location
  resource_group_name = azurerm_resource_group.rg.name
}


resource "azurerm_bot_connection" "graph" {
  name                  = "graph"
  bot_name              = azurerm_bot_service_azure_bot.teamsbot.name
  location              = azurerm_bot_service_azure_bot.teamsbot.location
  resource_group_name   = azurerm_resource_group.rg.name
  service_provider_name = "Aadv2"
  client_id             = azuread_application.teams-sso.client_id
  client_secret         = azuread_application_password.this.value
  scopes = "openid profile User.Read"
  parameters = {
    tenantId = data.azurerm_client_config.current.tenant_id
  }
}