variable "name" { type = string }
variable "location" { type = string }
variable "resource_group_name" { type = string }
variable "vm_size" { type = string }
variable "nic_id" { type = string }
variable "admin_username" { type = string }
variable "admin_password" {
  type = string
  default = ""
  sensitive = true
}
variable "ssh_public_key" {
  type = string
  default = ""
}
variable "os_disk_size_gb" {
  type = number
  default = 30
}
variable "os_disk_type" {
  type = string
  default = "Standard_LRS"
}
variable "os_publisher" {
  type = string
  default = "Canonical"
}
variable "os_offer" {
  type = string
  default = "0001-com-ubuntu-server-jammy"
}
variable "os_sku" {
  type = string
  default = "22_04-lts-gen2"
}
variable "os_version" {
  type = string
  default = "latest"
}
variable "tags" {
  type = map(string)
  default = {}
}
