output "terraform_role_arn" {
  description = "Usar em .github/workflows/terraform.yml"
  value       = aws_iam_role.terraform.arn
}

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

    Bootstrap concluído. A partir daqui, nada mais é aplicado localmente.

    1. Confira se os ARNs acima batem com os dos workflows em .github/workflows/
    2. Crie o secret EKS_ADMIN_IAM_ARN no GitHub:
       Settings > Secrets and variables > Actions > New repository secret
    3. Provisione a plataforma pela esteira:
       Actions > "Terraform — Plan e Apply" > Run workflow
         environment: prod
         action: apply
  EOT
}
