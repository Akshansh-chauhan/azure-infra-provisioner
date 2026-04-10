variable "name" { type = string }
variable "location" { type = string }
variable "resource_group_name" { type = string }
variable "sku_name" {
  type = string
  default = "standard"
}
variable "purge_protection" {
  type = bool
  default = false
}
variable "soft_delete_days" {
  type    = number
  default = 30
}
variable "tags" {
  type = map(string)
  default = {}
}
