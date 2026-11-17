data "aws_caller_identity" "current" {}

resource "aws_ecr_repository" "this" {
  for_each = var.create_ecr ? toset(var.services) : toset([])

  name                 = "${var.project}/${each.value}"
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = merge(local.common_tags, {
    Name    = "${var.project}/${each.value}"
    Service = each.value
  })
}

# Mantem apenas as 10 imagens mais recentes — evita crescimento indefinido do custo de storage.
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

# Replicacao cross-region: garante que as imagens estejam disponiveis na regiao de DR
# antes de um desastre. Sem isso, o cluster espelho sobe sem conseguir puxar imagens.
resource "aws_ecr_replication_configuration" "this" {
  count = var.create_ecr && var.ecr_replication_region != "" ? 1 : 0

  replication_configuration {
    rule {
      destination {
        region      = var.ecr_replication_region
        registry_id = data.aws_caller_identity.current.account_id
      }

      repository_filter {
        filter      = var.project
        filter_type = "PREFIX_MATCH"
      }
    }
  }
}
