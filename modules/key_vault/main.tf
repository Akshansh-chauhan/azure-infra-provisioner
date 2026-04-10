data "azurerm_client_config" "current" {}

resource "azurerm_key_vault" "this" {
  name                        = var.name
  location                    = var.location
  resource_group_name         = var.resource_group_name
  tenant_id                   = data.azurerm_client_config.current.tenant_id
  sku_name                    = var.sku_name
  soft_delete_retention_days  = var.soft_delete_days
  purge_protection_enabled    = var.purge_protection
  tags                        = var.tags

  access_policy {
    tenant_id = data.azurerm_client_config.current.tenant_id
    object_id = data.azurerm_client_config.current.object_id

    key_permissions    = ["Get", "List", "Create", "Delete", "Purge", "Recover"]
    secret_permissions = ["Get", "List", "Set", "Delete", "Purge", "Recover"]
  }

  network_acls {
    default_action = "Allow"
    bypass         = "AzureServices"
  }
}
