variable "name" { type = string }
variable "location" { type = string }
variable "resource_group_name" { type = string }
variable "allow_ssh" {
  type = bool
  default = true
}
variable "allow_http" {
  type = bool
  default = false
}
variable "allow_https" {
  type = bool
  default = false
}
variable "subnet_ids" {
  type = list(string)
  default = []
}
variable "tags" {
  type = map(string)
  default = {}
}

variable "custom_rules" {
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
