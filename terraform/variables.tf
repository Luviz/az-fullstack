variable "subscription_id" {
  description = "Azure subscription ID to deploy into."
  type        = string
}

variable "tenant_id" {
  description = "Entra ID tenant ID."
  type        = string
}

variable "project" {
  description = "Short project name used in resource names."
  type        = string
  default     = "azfullstack"
}

variable "environment" {
  description = "Environment name (dev, test, prod)."
  type        = string
  default     = "dev"
}

variable "location" {
  description = "Region for the resource group and Function App."
  type        = string
  default     = "westeurope"
}

variable "static_web_app_location" {
  description = "Region for the Static Web App (limited set: westeurope, eastus2, centralus, westus2, eastasia)."
  type        = string
  default     = "westeurope"
}

variable "node_version" {
  description = "Node.js runtime version for the Function App."
  type        = string
  default     = "22"
}

variable "function_max_instance_count" {
  description = "Maximum scale-out instances for the Flex Consumption plan."
  type        = number
  default     = 40
}

variable "function_instance_memory_mb" {
  description = "Instance memory size for the Flex Consumption plan (512, 2048 or 4096)."
  type        = number
  default     = 2048
}

variable "tags" {
  description = "Extra tags applied to all resources."
  type        = map(string)
  default     = {}
}
