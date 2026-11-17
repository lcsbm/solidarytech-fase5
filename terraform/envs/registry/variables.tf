variable "project" {
  description = "Prefixo dos repositórios ECR"
  type        = string
  default     = "solidarytech"
}

variable "primary_region" {
  description = "Região onde o CI publica as imagens"
  type        = string
  default     = "us-east-1"
}

variable "dr_region" {
  description = "Região que recebe as réplicas — a mesma do ambiente de DR"
  type        = string
  default     = "us-east-2"
}
