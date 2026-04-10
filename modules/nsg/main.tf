resource "azurerm_network_security_group" "this" {
  name                = var.name
  location            = var.location
  resource_group_name = var.resource_group_name
  tags                = var.tags
}

# --- Built-in rules (conditionally created) ---

resource "azurerm_network_security_rule" "allow_ssh" {
  count                       = var.allow_ssh ? 1 : 0
  name                        = "Allow-SSH"
  priority                    = 100
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "22"
  source_address_prefix       = "*"
  destination_address_prefix  = "*"
  resource_group_name         = var.resource_group_name
  network_security_group_name = azurerm_network_security_group.this.name
}

resource "azurerm_network_security_rule" "allow_http" {
  count                       = var.allow_http ? 1 : 0
  name                        = "Allow-HTTP"
  priority                    = 200
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "80"
  source_address_prefix       = "*"
  destination_address_prefix  = "*"
  resource_group_name         = var.resource_group_name
  network_security_group_name = azurerm_network_security_group.this.name
}

resource "azurerm_network_security_rule" "allow_https" {
  count                       = var.allow_https ? 1 : 0
  name                        = "Allow-HTTPS"
  priority                    = 300
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "443"
  source_address_prefix       = "*"
  destination_address_prefix  = "*"
  resource_group_name         = var.resource_group_name
  network_security_group_name = azurerm_network_security_group.this.name
}

# --- Custom rules ---

resource "azurerm_network_security_rule" "custom" {
  count                       = length(var.custom_rules)
  name                        = var.custom_rules[count.index].name
  priority                    = var.custom_rules[count.index].priority
  direction                   = var.custom_rules[count.index].direction
  access                      = var.custom_rules[count.index].access
  protocol                    = var.custom_rules[count.index].protocol
  source_port_range           = var.custom_rules[count.index].source_port_range
  destination_port_range      = var.custom_rules[count.index].destination_port_range
  source_address_prefix       = var.custom_rules[count.index].source_address_prefix
  destination_address_prefix  = var.custom_rules[count.index].destination_address_prefix
  resource_group_name         = var.resource_group_name
  network_security_group_name = azurerm_network_security_group.this.name
}

# --- Associate NSG with subnets ---

resource "azurerm_subnet_network_security_group_association" "this" {
  count                     = length(var.subnet_ids)
  subnet_id                 = var.subnet_ids[count.index]
  network_security_group_id = azurerm_network_security_group.this.id
}
