variable vnet {
  description = "The name of the Virtual Network"
  type        = string
}

variable location {
  description = "The Azure region to deploy resources"
  type        = string
}

variable rg {
  description = "The name of the Resource Group"
  type        = string
}

variable cidr {
  description = "The address space for the Virtual Network"
  type        = list(string)
}

variable subnet {
  description = "The address prefixes for the subnet"
  type        = list(string)
}

variable aks {
  description = "The name of the AKS cluster"
  type        = string
}

variable system_size {
  description = "The VM size for the system node pool"
  type        = string
}

variable user_size {
  description = "The VM size for the user node pool"
  type        = string
}