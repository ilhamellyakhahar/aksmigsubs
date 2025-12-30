resource "azurerm_virtual_network" "vnet" {
  name                = var.vnet
  location            = var.location
  resource_group_name = var.rg
  address_space       = var.cidr

  subnet {
    name             = "aks-subnet"
    address_prefixes = var.subnet
  }
}

locals {
  aks_subnet_id = "${azurerm_virtual_network.vnet.id}/subnets/aks-subnet"
}

resource "azurerm_kubernetes_cluster" "aks" {
  name                = var.aks
  location            = var.location
  resource_group_name = var.rg
  dns_prefix          = var.aks

  identity {
    type = "SystemAssigned"
  }

  default_node_pool {
    name       = "agentpool"
    node_count = 1
    vm_size    = var.system_size
    vnet_subnet_id = local.aks_subnet_id
  }

  network_profile {
    network_plugin    = "azure"
    network_plugin_mode = "overlay"
    load_balancer_sku = "standard"
  }
}

resource "azurerm_kubernetes_cluster_node_pool" "nodepool" {
  name                  = "userpool"
  kubernetes_cluster_id = azurerm_kubernetes_cluster.aks.id
  vm_size               = var.user_size
  auto_scaling_enabled   = true
  min_count             = 1
  max_count             = 5
  max_pods              = 200
  vnet_subnet_id        = local.aks_subnet_id
}