# Repositórios ECR de uma região. Chamado uma vez por região em envs/registry,
# para que os repos de DR nasçam com as mesmas garantias dos primários: tags
# imutáveis, scan no push, lifecycle e tags FinOps. Sem isso, a replicação os
# criaria sozinha — com defaults e sem tag alguma.
#
# Módulo pequeno de propósito: variáveis e outputs ficam neste único arquivo.
terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

variable "project" {
  description = "Prefixo dos repositórios"
  type        = string
}

variable "services" {
  description = "Um repositório por serviço"
  type        = list(string)
}

resource "aws_ecr_repository" "this" {
  for_each = toset(var.services)

  name                 = "${var.project}/${each.value}"
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = {
    Name    = "${var.project}/${each.value}"
    Service = each.value
  }
}

# Mantém apenas as 10 imagens mais recentes — evita crescimento indefinido do custo de storage.
resource "aws_ecr_lifecycle_policy" "this" {
  for_each = aws_ecr_repository.this

  repository = each.value.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Retem apenas as 10 imagens mais recentes"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 10
      }
      action = { type = "expire" }
    }]
  })
}

output "repository_urls" {
  description = "URL de cada repositório, por serviço"
  value       = { for k, v in aws_ecr_repository.this : k => v.repository_url }
}
