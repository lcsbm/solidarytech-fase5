variable "project" {
  description = "Nome do projeto — prefixo dos repositórios ECR e clusters"
  type        = string
  default     = "solidarytech"
}

variable "aws_region" {
  description = "Região onde o bucket de state é criado"
  type        = string
  default     = "us-east-1"
}

variable "github_repo" {
  description = "Repositório autorizado a assumir as roles, no formato owner/repo"
  type        = string
  default     = "lcsbm/solidarytech-fase5"
}

variable "github_owner_id" {
  description = "ID numérico do owner no GitHub (GET /users/<owner> → id). Pina a trust ao ID, não só ao nome"
  type        = string
  default     = "53958058"
}

variable "github_repo_id" {
  description = "ID numérico do repositório (GET /repos/<owner>/<repo> → id)"
  type        = string
  default     = "1460863773"
}

variable "role_prefix" {
  description = "Prefixo das roles de CI/CD. Distinto do usado na Fase 4 para não colidir"
  type        = string
  default     = "SolidaryTech-CICD"
}

variable "state_bucket_name" {
  description = "Bucket S3 do state remoto — deve bater com o backend.tf dos ambientes"
  type        = string
  default     = "solidarytech-tfstate"
}

variable "create_state_bucket" {
  description = "false se o bucket já foi criado manualmente no console"
  type        = bool
  default     = true
}

variable "create_oidc_provider" {
  description = <<-EOT
    Cria o provider OIDC do GitHub. Ele é único por conta e já existe nesta
    (criado na Fase 4), por isso o default é false. Mantê-lo não deixa acesso
    residual: o provider só federa identidades — quem concede acesso é a trust
    policy de cada role. Mude para true apenas em uma conta onde ele não exista.
  EOT
  type        = bool
  default     = false
}
