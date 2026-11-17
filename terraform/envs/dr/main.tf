terraform {
  required_version = ">= 1.6"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = "SolidaryTech"
      Environment = "DR"
      CostCenter  = "NGO-Core"
      ManagedBy   = "Terraform"
    }
  }
}

# Ambiente espelho (Warm Standby) em us-east-2.
#
# Usa exatamente o mesmo modulo do ambiente primario — a unica diferenca sao os
# parametros abaixo. Isso garante que o DR nao diverge da producao ao longo do tempo.
#
#   cd terraform/envs/dr && terraform init && terraform apply
#
# CIDR distinto do primario (10.1 vs 10.0) para permitir VPC peering sem conflito.
module "platform" {
  source = "../../modules/platform"

  project     = var.project
  environment = "DR"
  aws_region  = var.aws_region
  vpc_cidr    = "10.1.0.0/16"

  eks_admin_iam_arn       = var.eks_admin_iam_arn
  eks_public_access_cidrs = var.eks_public_access_cidrs

  # Warm standby: capacidade minima ligada. O failover escala via
  # `kubectl scale` ou ajustando eks_desired_nodes e reaplicando.
  eks_desired_nodes = var.warm_standby_nodes
  eks_min_nodes     = 1
  eks_max_nodes     = 4

  # Sem node group Spot no DR: durante um desastre a capacidade precisa ser
  # garantida, e instancias Spot podem ser interrompidas pela AWS.
  enable_spot_node_group = false

  # O ECR vive no primario e replica para ca — nao recriar aqui.
  create_ecr = false

  rds_backup_retention_days = 7
  dynamodb_enable_pitr      = true
}
