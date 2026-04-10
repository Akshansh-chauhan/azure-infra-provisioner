# =============================================================================
# Example Configuration - DO NOT USE DIRECTLY
# This shows what the Bash script auto-generates
# =============================================================================

# --- Global ---
project_name = "myapp"
environment  = "dev"
region       = "eastus"

tags = {
  GeneratedBy = "azure-infra-provisioner"
  Team        = "devops"
}

# --- Network ---
vnet_address_space = ["10.0.0.0/16"]
subnet_count       = 2
subnet_prefixes    = [
  "10.0.1.0/24",
  "10.0.2.0/24"
]

# --- NSG ---
allow_ssh   = true
allow_http  = true
allow_https = true

# --- Virtual Machines ---
vm_count = 3

vm_configs = [
  {
    vm_size          = "Standard_B2s"
    os_publisher     = "Canonical"
    os_offer         = "0001-com-ubuntu-server-jammy"
    os_sku           = "22_04-lts-gen2"
    os_version       = "latest"
    disk_size_gb     = 30
    disk_type        = "StandardSSD_LRS"
    admin_username   = "azureadmin"
    admin_password   = ""
    ssh_public_key   = "ssh-rsa AAAA...your-key-here..."
    assign_public_ip = true
  },
  {
    vm_size          = "Standard_D2s_v3"
    os_publisher     = "Canonical"
    os_offer         = "0001-com-ubuntu-server-focal"
    os_sku           = "20_04-lts-gen2"
    os_version       = "latest"
    disk_size_gb     = 50
    disk_type        = "Premium_LRS"
    admin_username   = "azureadmin"
    admin_password   = ""
    ssh_public_key   = "ssh-rsa AAAA...your-key-here..."
    assign_public_ip = true
  },
  {
    vm_size          = "Standard_B1s"
    os_publisher     = "Debian"
    os_offer         = "debian-11"
    os_sku           = "11-gen2"
    os_version       = "latest"
    disk_size_gb     = 30
    disk_type        = "Standard_LRS"
    admin_username   = "devadmin"
    admin_password   = ""
    ssh_public_key   = "ssh-rsa AAAA...your-key-here..."
    assign_public_ip = false
  },
]

# --- Storage Account ---
enable_storage_account   = true
storage_account_tier     = "Standard"
storage_replication_type = "LRS"
storage_account_kind     = "StorageV2"

# --- Key Vault ---
enable_key_vault        = true
keyvault_sku            = "standard"
keyvault_purge_on_destroy = true

# --- Load Balancer ---
enable_load_balancer = true
lb_sku               = "Standard"
