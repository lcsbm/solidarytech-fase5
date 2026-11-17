variable "project" {
  description = "Nome do projeto — prefixo dos recursos"
  type        = string
  default     = "solidarytech"
}

variable "aws_region" {
  description = "Regiao primaria"
  type        = string
  default     = "us-east-1"
}

variable "dr_region" {
  description = "Regiao de DR — destino da replicacao do ECR"
  type        = string
  default     = "us-east-2"
}

variable "eks_admin_iam_arn" {
  description = "ARN do usuario/role IAM com acesso de admin ao cluster"
  type        = string
}

variable "eks_public_access_cidrs" {
  description = "CIDRs autorizados no endpoint publico do EKS"
  type        = list(string)
  default     = ["0.0.0.0/0"]
}
