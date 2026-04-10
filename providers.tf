terraform {
  required_version = ">= 1.5.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.80"
    }
  }

  # Uncomment to use remote state (recommended for teams)
  # backend "azurerm" {
  #   resource_group_name  = "tfstate-rg"
  #   storage_account_name = "tfstatestore"
  #   container_name       = "tfstate"
  #   key                  = "infrastructure.tfstate"
  # }
}

provider "azurerm" {
  skip_provider_registration = true
  features {
    key_vault {
      purge_soft_delete_on_destroy    = var.keyvault_purge_on_destroy
      recover_soft_deleted_key_vaults = true
    }
    virtual_machine {
      graceful_shutdown = false
    }
  }
}
