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

resource "azurerm_kubernetes_cluster" "aks" {
  name                = var.aks
  location            = var.location
  resource_group_name = var.rg

  default_node_pool {
    name       = "agentpool"
    node_count = 1
    vm_size    = var.system_size
  }
}

resource "azurerm_kubernetes_cluster_node_pool" "nodepool" {
  name                  = "userpool"
  kubernetes_cluster_id = azurerm_kubernetes_cluster.aks.id
  vm_size               = var.user_size
  enable_auto_scaling   = true
  min_count             = 1
  max_count             = 5
  max_pods              = 200
}