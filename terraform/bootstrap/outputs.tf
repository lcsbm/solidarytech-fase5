output "ecr_push_role_arn" {
  description = "Usar em .github/workflows/ci.yml"
  value       = aws_iam_role.ecr_push.arn
}

output "state_bucket" {
  description = "Bucket do state remoto — deve bater com o backend.tf dos ambientes"
  value       = var.state_bucket_name
}

output "proximos_passos" {
  description = "O que fazer depois deste apply"
  value       = <<-EOT

    Bootstrap concluído. Daqui em diante tudo passa pela esteira.

    1. Actions > "Terraform — Plan e Apply" > environment: registry > action: apply
    2. Actions > "Terraform — Plan e Apply" > environment: prod     > action: apply
    3. Siga docs/RUNBOOK-primeiro-deploy.md a partir do passo 4
  EOT
}
