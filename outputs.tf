# =============================================================================
# OUTPUTS - Useful info displayed after terraform apply
# =============================================================================

output "resource_group_name" {
  description = "Name of the created resource group"
  value       = module.resource_group.name
}

output "resource_group_id" {
  description = "ID of the created resource group"
  value       = module.resource_group.id
}

output "vnet_name" {
  description = "Virtual network name"
  value       = module.virtual_network.name
}

output "vnet_id" {
  description = "Virtual network ID"
  value       = module.virtual_network.id
}

output "subnet_ids" {
  description = "List of subnet IDs"
  value       = [for s in module.subnet : s.id]
}

output "vm_names" {
  description = "Names of provisioned VMs"
  value       = [for vm in module.virtual_machine : vm.name]
}

output "vm_private_ips" {
  description = "Private IPs of provisioned VMs"
  value       = [for nic in module.nic : nic.private_ip]
}

output "vm_public_ips" {
  description = "Public IPs (if assigned)"
  value       = [for pip in module.public_ip : pip.ip_address]
}

output "storage_account_name" {
  description = "Storage account name (if created)"
  value       = var.enable_storage_account ? module.storage_account[0].name : "N/A"
}

output "key_vault_uri" {
  description = "Key Vault URI (if created)"
  value       = var.enable_key_vault ? module.key_vault[0].vault_uri : "N/A"
}

output "load_balancer_ip" {
  description = "Load balancer public IP (if created)"
  value       = var.enable_load_balancer ? module.load_balancer[0].public_ip : "N/A"
}

output "ssh_commands" {
  description = "SSH commands to connect to VMs with public IPs"
  value       = [for pip in module.public_ip : "ssh user@${pip.ip_address}"]
}
