output "resource_group_name" {
  value = module.resource_group.name
}

output "static_web_app_name" {
  value = module.web.name
}

output "static_web_app_url" {
  value = "https://${module.web.resource_uri}"
}

output "static_web_app_api_key" {
  description = "Deployment token for the SWA CLI / GitHub Action."
  value       = module.web.api_key
  sensitive   = true
}

output "function_app_name" {
  value = module.func.name
}

output "function_app_url" {
  value = "https://${module.func.resource_uri}"
}

output "cicd_client_id" {
  description = "Client ID for azure/login in GitHub Actions."
  value       = module.cicd_identity.client_id
}
