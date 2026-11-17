variable "project" {
  description = "Nome do projeto — prefixo de todos os recursos"
  type        = string
  default     = "solidarytech"
}

variable "environment" {
  description = "Ambiente — compõe a tag FinOps Environment (Production | DR)"
  type        = string

  validation {
    condition     = contains(["Production", "DR"], var.environment)
    error_message = "environment deve ser 'Production' ou 'DR'."
  }
}

variable "cost_center" {
  description = "Centro de custo — tag FinOps obrigatória"
  type        = string
  default     = "NGO-Core"
}

variable "aws_region" {
  description = "Região AWS onde a stack é provisionada"
  type        = string
}

variable "vpc_cidr" {
  description = "CIDR da VPC — deve diferir entre prod e DR para permitir peering futuro"
  type        = string
}

# ── EKS ──
variable "eks_cluster_version" {
  description = <<-EOT
    Versão do Kubernetes no EKS.

    FinOps: manter em SUPORTE PADRÃO (US$ 0,10/h). Versões em suporte estendido
    custam US$ 0,60/h — 6x mais, ou ~US$ 365/mês adicionais por cluster.
    Conferir o calendário antes de fixar:
    https://docs.aws.amazon.com/eks/latest/userguide/kubernetes-versions.html
  EOT
  type        = string
  default     = "1.36"
}

variable "eks_node_type" {
  description = "Tipo de instância dos nós worker"
  type        = string
  default     = "t3.medium"
}

variable "eks_min_nodes" {
  description = "Mínimo de nós no node group"
  type        = number
  default     = 2
}

variable "eks_max_nodes" {
  description = "Máximo de nós no node group"
  type        = number
  default     = 4
}

variable "eks_desired_nodes" {
  description = "Quantidade desejada de nós. No DR (warm standby) use 1 para reduzir custo"
  type        = number
  default     = 2
}

variable "eks_public_access_cidrs" {
  description = "CIDRs autorizados a acessar o endpoint público do EKS"
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "eks_admin_iam_arn" {
  description = "ARN do principal IAM que recebe acesso de admin no cluster"
  type        = string
}

# ── FinOps: Spot Instances ──
variable "enable_spot_node_group" {
  description = "Cria um node group Spot para cargas não-críticas (ngo/volunteer) — economia ~65%"
  type        = bool
  default     = true
}

variable "spot_instance_types" {
  description = "Tipos elegíveis para o node group Spot — múltiplos tipos reduzem risco de interrupção"
  type        = list(string)
  default     = ["t3.medium", "t3a.medium", "t2.medium"]
}

variable "spot_desired_nodes" {
  description = "Quantidade desejada de nós Spot"
  type        = number
  default     = 2
}

# ── RDS ──
variable "rds_instance_class" {
  description = "Classe das instâncias RDS PostgreSQL"
  type        = string
  default     = "db.t3.micro"
}

variable "rds_allocated_storage" {
  description = "Armazenamento em GB por instância RDS"
  type        = number
  default     = 20
}

variable "rds_backup_retention_days" {
  description = "Retenção de snapshots automáticos — base do RPO definido no PCN"
  type        = number
  default     = 7
}

# ── DynamoDB ──
variable "dynamodb_enable_pitr" {
  description = "Point-in-Time Recovery no DynamoDB — reduz o RPO para ~5 minutos"
  type        = bool
  default     = true
}
