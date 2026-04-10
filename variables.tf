# =============================================================================
# GLOBAL CONFIGURATION
# =============================================================================

variable "project_name" {
  description = "Project name used as prefix for all resources"
  type        = string
  validation {
    condition     = can(regex("^[a-z0-9-]{3,24}$", var.project_name))
    error_message = "Project name must be 3-24 chars, lowercase alphanumeric and hyphens only."
  }
}

variable "environment" {
  description = "Environment tag (dev, staging, prod)"
  type        = string
  default     = "dev"
  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "Environment must be dev, staging, or prod."
  }
}

variable "region" {
  description = "Azure region for all resources"
  type        = string
  default     = "eastus"
}

variable "tags" {
  description = "Common tags applied to all resources"
  type        = map(string)
  default     = {}
}

# =============================================================================
# VIRTUAL NETWORK
# =============================================================================

variable "vnet_address_space" {
  description = "Address space for the virtual network"
  type        = list(string)
  default     = ["10.0.0.0/16"]
}

variable "dns_servers" {
  description = "Custom DNS servers (empty = Azure default)"
  type        = list(string)
  default     = []
}

variable "subnet_count" {
  description = "Number of subnets to create"
  type        = number
  default     = 1
  validation {
    condition     = var.subnet_count >= 1 && var.subnet_count <= 10
    error_message = "Subnet count must be between 1 and 10."
  }
}

variable "subnet_prefixes" {
  description = "CIDR prefixes for each subnet"
  type        = list(string)
  default     = ["10.0.1.0/24"]
}

# =============================================================================
# NETWORK SECURITY GROUP
# =============================================================================

variable "allow_ssh" {
  description = "Allow SSH (port 22) inbound"
  type        = bool
  default     = true
}

variable "allow_http" {
  description = "Allow HTTP (port 80) inbound"
  type        = bool
  default     = false
}

variable "allow_https" {
  description = "Allow HTTPS (port 443) inbound"
  type        = bool
  default     = false
}

variable "custom_nsg_rules" {
  description = "Additional custom NSG rules"
  type = list(object({
    name                       = string
    priority                   = number
    direction                  = string
    access                     = string
    protocol                   = string
    source_port_range          = string
    destination_port_range     = string
    source_address_prefix      = string
    destination_address_prefix = string
  }))
  default = []
}

# =============================================================================
# VIRTUAL MACHINES
# =============================================================================

variable "vm_count" {
  description = "Number of virtual machines to provision (0 = no VMs)"
  type        = number
  default     = 0
  validation {
    condition     = var.vm_count >= 0 && var.vm_count <= 50
    error_message = "VM count must be between 0 and 50."
  }
}

variable "vm_configs" {
  description = "Per-VM configuration list"
  type = list(object({
    vm_size        = string
    os_publisher   = string
    os_offer       = string
    os_sku         = string
    os_version     = string
    disk_size_gb   = number
    disk_type      = string
    admin_username = string
    admin_password = string
    ssh_public_key = string
    assign_public_ip = bool
  }))
  default = []
}

# =============================================================================
# STORAGE ACCOUNT
# =============================================================================

variable "enable_storage_account" {
  description = "Create a storage account"
  type        = bool
  default     = true
}

variable "storage_account_tier" {
  description = "Storage account tier"
  type        = string
  default     = "Standard"
  validation {
    condition     = contains(["Standard", "Premium"], var.storage_account_tier)
    error_message = "Storage tier must be Standard or Premium."
  }
}

variable "storage_replication_type" {
  description = "Storage replication type"
  type        = string
  default     = "LRS"
  validation {
    condition     = contains(["LRS", "GRS", "ZRS", "RAGRS"], var.storage_replication_type)
    error_message = "Replication must be LRS, GRS, ZRS, or RAGRS."
  }
}

variable "storage_account_kind" {
  description = "Storage account kind"
  type        = string
  default     = "StorageV2"
}

# =============================================================================
# KEY VAULT
# =============================================================================

variable "enable_key_vault" {
  description = "Create a Key Vault"
  type        = bool
  default     = false
}

variable "keyvault_sku" {
  description = "Key Vault SKU"
  type        = string
  default     = "standard"
  validation {
    condition     = contains(["standard", "premium"], var.keyvault_sku)
    error_message = "Key Vault SKU must be standard or premium."
  }
}

variable "keyvault_purge_on_destroy" {
  description = "Purge Key Vault on destroy"
  type        = bool
  default     = true
}

# =============================================================================
# LOAD BALANCER
# =============================================================================

variable "enable_load_balancer" {
  description = "Create a load balancer in front of VMs"
  type        = bool
  default     = false
}

variable "lb_sku" {
  description = "Load balancer SKU"
  type        = string
  default     = "Standard"
  validation {
    condition     = contains(["Basic", "Standard"], var.lb_sku)
    error_message = "LB SKU must be Basic or Standard."
  }
}
