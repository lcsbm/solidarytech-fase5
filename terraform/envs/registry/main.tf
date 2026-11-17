terraform {
  required_version = ">= 1.6"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

# O registro de imagens tem ciclo de vida próprio: sobrevive a subir e derrubar
# qualquer cluster. Por isso é um root separado de prod e dr, com state próprio,
# e não aparece no workflow de destroy — apagar o registro apaga todas as
# imagens das duas regiões, e isso é ação manual e deliberada.
locals {
  # Environment = Shared: o registro serve produção e DR. Separar seu custo
  # dos clusters é exatamente o que a tag permite.
  finops_tags = {
    Project     = "SolidaryTech"
    Environment = "Shared"
    CostCenter  = "NGO-Core"
    ManagedBy   = "Terraform"
  }

  services = ["ngo-service", "donation-service", "volunteer-service"]
}

provider "aws" {
  region = var.primary_region

  default_tags {
    tags = local.finops_tags
  }
}

provider "aws" {
  alias  = "dr"
  region = var.dr_region

  default_tags {
    tags = local.finops_tags
  }
}

data "aws_caller_identity" "current" {}

module "primary" {
  source = "../../modules/registry"

  project  = var.project
  services = local.services
}

module "dr" {
  source = "../../modules/registry"
  providers = {
    aws = aws.dr
  }

  project  = var.project
  services = local.services
}

# O CI publica apenas no primário; a AWS copia cada imagem para o DR. Como os
# repositórios de destino já existem (module.dr), as cópias chegam em repos com
# as mesmas garantias — e não em repos auto-criados sem tags nem lifecycle.
resource "aws_ecr_replication_configuration" "this" {
  replication_configuration {
    rule {
      destination {
        region      = var.dr_region
        registry_id = data.aws_caller_identity.current.account_id
      }

      repository_filter {
        filter      = var.project
        filter_type = "PREFIX_MATCH"
      }
    }
  }

  depends_on = [module.dr]
}
