output "cluster_name" {
  value = module.platform.cluster_name
}

output "configure_kubectl" {
  value = module.platform.configure_kubectl
}

output "rds_endpoints" {
  value = module.platform.rds_endpoints
}

output "dynamodb_table_name" {
  value = module.platform.dynamodb_table_name
}

output "sqs_queue_url" {
  value = module.platform.sqs_queue_url
}

output "ecr_repository_urls" {
  value = module.platform.ecr_repository_urls
}

output "irsa_role_arns" {
  description = "ARNs para as annotations eks.amazonaws.com/role-arn nos ServiceAccounts"
  value       = module.platform.irsa_role_arns
}
