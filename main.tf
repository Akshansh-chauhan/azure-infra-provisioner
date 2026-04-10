# =============================================================================
# ROOT MODULE - Composes all child modules with dependency ordering
# =============================================================================

locals {
  common_tags = merge(var.tags, {
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "terraform"
    Provisioner = "azure-infra-provisioner"
  })

  # Naming convention: {project}-{environment}-{resource}
  name_prefix = "${var.project_name}-${var.environment}"

  # VM indices that have public IPs enabled
  pip_vm_indices = [for i, vm in var.vm_configs : i if vm.assign_public_ip]

  # Map: VM index (as string) -> public IP module index
  pip_indices = { for pip_idx, vm_idx in local.pip_vm_indices : tostring(vm_idx) => pip_idx }
}

# -----------------------------------------------------------------------------
# 1. Resource Group (everything depends on this)
# -----------------------------------------------------------------------------
module "resource_group" {
  source = "./modules/resource_group"

  name     = "${local.name_prefix}-rg"
  location = var.region
  tags     = local.common_tags
}

# -----------------------------------------------------------------------------
# 2. Virtual Network
# -----------------------------------------------------------------------------
module "virtual_network" {
  source = "./modules/virtual_network"

  name                = "${local.name_prefix}-vnet"
  location            = module.resource_group.location
  resource_group_name = module.resource_group.name
  address_space       = var.vnet_address_space
  dns_servers         = var.dns_servers
  tags                = local.common_tags
}

# -----------------------------------------------------------------------------
# 3. Subnets
# -----------------------------------------------------------------------------
module "subnet" {
  source = "./modules/subnet"

  count               = var.subnet_count
  name                = "${local.name_prefix}-subnet-${count.index + 1}"
  resource_group_name = module.resource_group.name
  vnet_name           = module.virtual_network.name
  address_prefix      = var.subnet_prefixes[count.index]
}

# -----------------------------------------------------------------------------
# 4. Network Security Group
# -----------------------------------------------------------------------------
module "nsg" {
  source = "./modules/nsg"

  name                = "${local.name_prefix}-nsg"
  location            = module.resource_group.location
  resource_group_name = module.resource_group.name
  allow_ssh           = var.allow_ssh
  allow_http          = var.allow_http
  allow_https         = var.allow_https
  custom_rules        = var.custom_nsg_rules
  subnet_ids          = [for s in module.subnet : s.id]
  tags                = local.common_tags
}

# -----------------------------------------------------------------------------
# 5. Public IPs (one per VM that has assign_public_ip = true)
# -----------------------------------------------------------------------------
module "public_ip" {
  source = "./modules/public_ip"

  count               = length(local.pip_vm_indices)
  name                = "${local.name_prefix}-pip-${local.pip_vm_indices[count.index] + 1}"
  location            = module.resource_group.location
  resource_group_name = module.resource_group.name
  tags                = local.common_tags
}

# -----------------------------------------------------------------------------
# 6. Network Interfaces (one per VM)
# -----------------------------------------------------------------------------
module "nic" {
  source = "./modules/nic"

  count               = var.vm_count
  name                = "${local.name_prefix}-nic-${count.index + 1}"
  location            = module.resource_group.location
  resource_group_name = module.resource_group.name
  subnet_id           = module.subnet[count.index % var.subnet_count].id
  public_ip_id        = contains(keys(local.pip_indices), tostring(count.index)) ? module.public_ip[local.pip_indices[tostring(count.index)]].id : null
  tags                = local.common_tags
}

# -----------------------------------------------------------------------------
# 7. Virtual Machines
# -----------------------------------------------------------------------------
module "virtual_machine" {
  source = "./modules/virtual_machine"

  count               = var.vm_count
  name                = "${local.name_prefix}-vm-${count.index + 1}"
  location            = module.resource_group.location
  resource_group_name = module.resource_group.name
  vm_size             = var.vm_configs[count.index].vm_size
  nic_id              = module.nic[count.index].id
  admin_username      = var.vm_configs[count.index].admin_username
  admin_password      = var.vm_configs[count.index].admin_password
  ssh_public_key      = var.vm_configs[count.index].ssh_public_key
  os_disk_size_gb     = var.vm_configs[count.index].disk_size_gb
  os_disk_type        = var.vm_configs[count.index].disk_type
  os_publisher        = var.vm_configs[count.index].os_publisher
  os_offer            = var.vm_configs[count.index].os_offer
  os_sku              = var.vm_configs[count.index].os_sku
  os_version          = var.vm_configs[count.index].os_version
  tags                = local.common_tags
}

# -----------------------------------------------------------------------------
# 8. Storage Account (optional)
# -----------------------------------------------------------------------------
module "storage_account" {
  source = "./modules/storage_account"

  count                = var.enable_storage_account ? 1 : 0
  name                 = substr(replace("${var.project_name}${var.environment}sa", "-", ""), 0, 24)
  location             = module.resource_group.location
  resource_group_name  = module.resource_group.name
  account_tier         = var.storage_account_tier
  replication_type     = var.storage_replication_type
  account_kind         = var.storage_account_kind
  tags                 = local.common_tags
}

# -----------------------------------------------------------------------------
# 9. Key Vault (optional)
# -----------------------------------------------------------------------------
module "key_vault" {
  source = "./modules/key_vault"

  count               = var.enable_key_vault ? 1 : 0
  name                = substr("${local.name_prefix}-kv", 0, 24)
  location            = module.resource_group.location
  resource_group_name = module.resource_group.name
  sku_name            = var.keyvault_sku
  purge_protection    = !var.keyvault_purge_on_destroy
  soft_delete_days    = var.environment == "prod" ? 90 : 30
  tags                = local.common_tags
}

# -----------------------------------------------------------------------------
# 10. Load Balancer (optional)
# -----------------------------------------------------------------------------
module "load_balancer" {
  source = "./modules/load_balancer"

  count               = var.enable_load_balancer ? 1 : 0
  name                = "${local.name_prefix}-lb"
  location            = module.resource_group.location
  resource_group_name = module.resource_group.name
  sku                 = var.lb_sku
  nic_ids             = [for nic in module.nic : nic.id]
  vm_count            = var.vm_count
  tags                = local.common_tags
}
