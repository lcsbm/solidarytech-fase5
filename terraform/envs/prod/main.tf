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

  # Tags FinOps aplicadas automaticamente a TODO recurso criado neste ambiente,
  # inclusive os gerados por submodulos de terceiros.
  default_tags {
    tags = {
      Project     = "SolidaryTech"
      Environment = "Production"
      CostCenter  = "NGO-Core"
      ManagedBy   = "Terraform"
    }
  }
}

module "platform" {
  source = "../../modules/platform"

  project     = var.project
  environment = "Production"
  aws_region  = var.aws_region
  vpc_cidr    = "10.0.0.0/16"

  eks_admin_iam_arn       = var.eks_admin_iam_arn
  eks_public_access_cidrs = var.eks_public_access_cidrs

  eks_desired_nodes = 2
  eks_min_nodes     = 2
  eks_max_nodes     = 4

  # FinOps: node group Spot para ngo-service e volunteer-service.
  enable_spot_node_group = true
  spot_desired_nodes     = 2

  # O ambiente primario e o dono dos repositorios ECR e replica para o DR.
  create_ecr             = true
  ecr_replication_region = var.dr_region

  rds_backup_retention_days = 7
  dynamodb_enable_pitr      = true
}
