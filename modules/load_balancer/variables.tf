variable "name" { type = string }
variable "location" { type = string }
variable "resource_group_name" { type = string }
variable "sku" {
  type = string
  default = "Standard"
}
variable "nic_ids" { type = list(string) }
variable "vm_count" { type = number }
variable "tags" {
  type = map(string)
  default = {}
}
