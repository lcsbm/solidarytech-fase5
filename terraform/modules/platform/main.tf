terraform {
  required_version = ">= 1.6"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  name_prefix = "${var.project}-${lower(var.environment)}"

  # Tags FinOps obrigatórias — aplicadas a todo recurso da plataforma.
  # Permitem rastrear custo por projeto/ambiente/centro de custo no Cost Explorer.
  common_tags = {
    Project     = "SolidaryTech"
    Environment = var.environment
    CostCenter  = var.cost_center
    ManagedBy   = "Terraform"
  }

  azs = slice(data.aws_availability_zones.available.names, 0, 2)
}

# ── Rede ──
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = "${local.name_prefix}-vpc"
  cidr = var.vpc_cidr

  azs             = local.azs
  public_subnets  = [cidrsubnet(var.vpc_cidr, 8, 1), cidrsubnet(var.vpc_cidr, 8, 2)]
  private_subnets = [cidrsubnet(var.vpc_cidr, 8, 3), cidrsubnet(var.vpc_cidr, 8, 4)]

  # NAT único: compromisso consciente de FinOps — reduz ~$32/mês por AZ extra.
  enable_nat_gateway   = true
  single_nat_gateway   = true
  enable_dns_hostnames = true
  enable_dns_support   = true

  public_subnet_tags  = { "kubernetes.io/role/elb" = "1" }
  private_subnet_tags = { "kubernetes.io/role/internal-elb" = "1" }

  tags = local.common_tags
}

# ── EKS ──
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.0"

  cluster_name    = local.name_prefix
  cluster_version = var.eks_cluster_version

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  cluster_endpoint_public_access           = true
  cluster_endpoint_public_access_cidrs     = var.eks_public_access_cidrs
  enable_cluster_creator_admin_permissions = true

  create_cloudwatch_log_group = false

  cluster_addons = {
    # Prefix Delegation eleva o limite de pods por nó de 17 para 110 no t3.medium.
    vpc-cni = {
      configuration_values = jsonencode({
        env = {
          ENABLE_PREFIX_DELEGATION = "true"
          WARM_PREFIX_TARGET       = "1"
        }
      })
    }
    aws-ebs-csi-driver = {
      most_recent              = true
      service_account_role_arn = module.ebs_csi_irsa.iam_role_arn
    }
    coredns    = {}
    kube-proxy = {}
  }

  eks_managed_node_groups = merge(
    {
      # On-Demand: cargas críticas (donation-service — Hot Path do SLO).
      ondemand = {
        ami_type       = "AL2023_x86_64_STANDARD"
        instance_types = [var.eks_node_type]
        capacity_type  = "ON_DEMAND"

        min_size     = var.eks_min_nodes
        max_size     = var.eks_max_nodes
        desired_size = var.eks_desired_nodes
        disk_size    = 20

        labels = { workload = "critical" }

        cloudinit_pre_nodeadm = [{
          content_type = "application/node.eks.aws"
          content = jsonencode({
            apiVersion = "node.eks.aws/v1alpha1"
            kind       = "NodeConfig"
            spec       = { kubelet = { config = { maxPods = 110 } } }
          })
        }]
      }
    },
    var.enable_spot_node_group ? {
      # Spot: economia de ~65% para ngo-service e volunteer-service.
      # O taint impede que cargas críticas caiam aqui sem tolerância explícita.
      spot = {
        ami_type       = "AL2023_x86_64_STANDARD"
        instance_types = var.spot_instance_types
        capacity_type  = "SPOT"

        min_size     = 1
        max_size     = 4
        desired_size = var.spot_desired_nodes
        disk_size    = 20

        labels = { workload = "burstable" }

        taints = {
          spot = {
            key    = "capacity-type"
            value  = "spot"
            effect = "NO_SCHEDULE"
          }
        }

        cloudinit_pre_nodeadm = [{
          content_type = "application/node.eks.aws"
          content = jsonencode({
            apiVersion = "node.eks.aws/v1alpha1"
            kind       = "NodeConfig"
            spec       = { kubelet = { config = { maxPods = 110 } } }
          })
        }]
      }
    } : {}
  )

  access_entries = {
    admin = {
      principal_arn = var.eks_admin_iam_arn
      policy_associations = {
        admin = {
          policy_arn   = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
          access_scope = { type = "cluster" }
        }
      }
    }
  }

  cluster_timeouts = {
    create = "30m"
    update = "60m"
    delete = "60m"
  }

  tags = local.common_tags
}
