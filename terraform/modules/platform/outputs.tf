output "cluster_name" {
  description = "Nome do cluster EKS"
  value       = module.eks.cluster_name
}

output "cluster_endpoint" {
  description = "Endpoint da API do cluster EKS"
  value       = module.eks.cluster_endpoint
}

output "cluster_certificate_authority_data" {
  description = "CA do cluster em base64 — consumido pelo provider helm no root module"
  value       = module.eks.cluster_certificate_authority_data
}

output "configure_kubectl" {
  description = "Comando para configurar o kubectl contra este cluster"
  value       = "aws eks update-kubeconfig --region ${var.aws_region} --name ${module.eks.cluster_name}"
}

output "vpc_id" {
  description = "ID da VPC"
  value       = module.vpc.vpc_id
}

output "rds_endpoints" {
  description = "Endpoints das instancias RDS por banco"
  value       = { for k, v in aws_db_instance.this : k => v.endpoint }
}

output "database_url_secret_names" {
  description = "Nomes das secrets com as connection strings — consumidas pelo External Secrets"
  value       = { for k, v in aws_secretsmanager_secret.db_url : k => v.name }
}

output "dynamodb_table_name" {
  description = "Nome da tabela DynamoDB de voluntarios"
  value       = aws_dynamodb_table.volunteers.name
}

output "sqs_queue_url" {
  description = "URL da fila SQS de doacoes"
  value       = aws_sqs_queue.donations.url
}

output "sqs_dlq_url" {
  description = "URL da dead letter queue de doacoes"
  value       = aws_sqs_queue.donations_dlq.url
}

output "ecr_repository_urls" {
  description = "URLs dos repositorios ECR (vazio quando create_ecr = false)"
  value       = { for k, v in aws_ecr_repository.this : k => v.repository_url }
}

output "irsa_role_arns" {
  description = "ARNs das roles IRSA — usados nas annotations dos ServiceAccounts"
  value = {
    external_secrets  = module.external_secrets_irsa.iam_role_arn
    volunteer_service = module.volunteer_irsa.iam_role_arn
    donation_service  = module.donation_irsa.iam_role_arn
  }
}

output "finops_tags" {
  description = "Tags FinOps aplicadas a toda a plataforma"
  value       = local.common_tags
}
