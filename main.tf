terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.49.0"
    }
  }
}

provider "azurerm" {
  features {}

  # Subscription ID will be read from ARM_SUBSCRIPTION_ID environment variable
  # or az account set
}

# ==============================
# Variables
# ==============================
variable "location"      { type = string }
variable "rg_name"       { type = string }
variable "vnet_name"     { type = string }
variable "subnet_name"   { type = string }
variable "aks_name"      { type = string }
variable "storage_name"  { type = string }
variable "share_name"    { type = string }

# ==============================
# Resource Group
# ==============================
resource "azurerm_resource_group" "rg" {
  name     = var.rg_name
  location = var.location
}

# ==============================
# Networking
# ==============================
resource "azurerm_virtual_network" "vnet" {
  name                = var.vnet_name
  location            = var.location
  resource_group_name = azurerm_resource_group.rg.name
  address_space       = ["10.20.0.0/16"]
}

resource "azurerm_subnet" "subnet" {
  name                 = var.subnet_name
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = ["10.20.1.0/24"]
  service_endpoints    = ["Microsoft.Storage"]
}

# ==============================
# Storage Account (NFS v4.1)
# ==============================
resource "azurerm_storage_account" "sa" {
  name                       = var.storage_name
  resource_group_name        = azurerm_resource_group.rg.name
  location                   = var.location
  account_tier               = "Premium"
  account_replication_type   = "LRS"
  account_kind               = "FileStorage"
  shared_access_key_enabled  = false  # Disabled by Azure policy
  https_traffic_only_enabled = false  # Required for NFS

  network_rules {
    default_action             = "Deny"
    virtual_network_subnet_ids = [azurerm_subnet.subnet.id]
    bypass                     = ["AzureServices"]
  }
}

# NFS share is managed outside Terraform via Azure CLI due to shared key access restrictions
# Created with: az storage share-rm create --resource-group oc-rg-eastasia \
#   --storage-account ocmsgsgenaipmodelweights --name ocmsgsgenaipmodelweights \
#   --enabled-protocols NFS --quota 1024

# ==============================
# Private Endpoint for NFS
# ==============================
resource "azurerm_private_endpoint" "pe_file" {
  name                = "${var.storage_name}-pe-file"
  location            = var.location
  resource_group_name = azurerm_resource_group.rg.name
  subnet_id           = azurerm_subnet.subnet.id

  private_service_connection {
    name                           = "${var.storage_name}-psc-file"
    private_connection_resource_id = azurerm_storage_account.sa.id
    subresource_names              = ["file"]
    is_manual_connection           = false
  }
}

# ==============================
# Private DNS Zone for privatelink.file.core.windows.net
# ==============================
resource "azurerm_private_dns_zone" "dns" {
  name                = "privatelink.file.core.windows.net"
  resource_group_name = azurerm_resource_group.rg.name
}

resource "azurerm_private_dns_zone_virtual_network_link" "dnslink" {
  name                  = "oc-vnet-link"
  resource_group_name   = azurerm_resource_group.rg.name
  virtual_network_id    = azurerm_virtual_network.vnet.id
  private_dns_zone_name = azurerm_private_dns_zone.dns.name
}

resource "azurerm_private_dns_a_record" "storage" {
  name                = var.storage_name
  zone_name           = azurerm_private_dns_zone.dns.name
  resource_group_name = azurerm_resource_group.rg.name
  ttl                 = 300
  records             = [azurerm_private_endpoint.pe_file.private_service_connection[0].private_ip_address]
}

# ==============================
# AKS Cluster (System-assigned Managed Identity)
# ==============================
resource "azurerm_kubernetes_cluster" "aks" {
  name                = var.aks_name
  location            = var.location
  resource_group_name = azurerm_resource_group.rg.name
  dns_prefix          = "${var.aks_name}-dns"
  kubernetes_version  = "1.33"

  default_node_pool {
    name            = "system"
    node_count      = 1
    vm_size         = "Standard_D4s_v5"
    vnet_subnet_id  = azurerm_subnet.subnet.id
    os_disk_size_gb = 128
  }

  identity {
    type = "SystemAssigned"
  }

  network_profile {
    network_plugin = "azure"
  }

  depends_on = [
    azurerm_private_endpoint.pe_file
  ]
}

# ==============================
# Outputs
# ==============================
output "resource_group" {
  value = azurerm_resource_group.rg.name
}

output "storage_account" {
  value = azurerm_storage_account.sa.name
}

output "nfs_share_path" {
  value = "${azurerm_storage_account.sa.name}.file.core.windows.net:/${var.share_name}"
}

output "aks_name" {
  value = azurerm_kubernetes_cluster.aks.name
}

output "private_endpoint_ip" {
  value = azurerm_private_endpoint.pe_file.private_service_connection[0].private_ip_address
}