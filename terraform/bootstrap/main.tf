terraform {
  required_version = ">= 1.6"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # Sem backend remoto: este é o único state que fica local, porque é este
  # código que cria o bucket onde todos os outros states vivem.
  #
  # Depois do primeiro apply o bucket já existe, e vale migrar este state para
  # ele — basta descomentar o bloco abaixo e rodar `terraform init -migrate-state`.
  # Sem isso, perder a máquina significa perder o rastreamento destes recursos.
  #
  # backend "s3" {
  #   bucket  = "solidarytech-tfstate"
  #   key     = "bootstrap/terraform.tfstate"
  #   region  = "us-east-1"
  #   encrypt = true
  # }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = "SolidaryTech"
      Environment = "Bootstrap"
      CostCenter  = "NGO-Core"
      ManagedBy   = "Terraform"
    }
  }
}

data "aws_caller_identity" "current" {}

locals {
  github_owner = split("/", var.github_repo)[0]
  github_repo  = split("/", var.github_repo)[1]

  # Dois formatos porque o GitHub pode emitir o sub com ou sem os IDs numéricos
  # de owner e repositório — as roles da Fase 4 nesta conta usam a forma com IDs
  # e funcionaram. Ambos fixam exatamente este repositório; o com IDs ainda
  # resiste à recriação do repo sob o mesmo nome por outra conta.
  # Após o primeiro deploy, o evento AssumeRoleWithWebIdentity no CloudTrail
  # mostra qual dos dois casou: remova o outro.
  repo_subjects = [
    "repo:${var.github_repo}:*",
    "repo:${local.github_owner}@${var.github_owner_id}/${local.github_repo}@${var.github_repo_id}:*",
  ]
}

# ── State remoto ──
resource "aws_s3_bucket" "tfstate" {
  count = var.create_state_bucket ? 1 : 0

  bucket = var.state_bucket_name
}

resource "aws_s3_bucket_versioning" "tfstate" {
  count = var.create_state_bucket ? 1 : 0

  bucket = aws_s3_bucket.tfstate[0].id

  # Obrigatório: permite recuperar o state após um apply corrompido.
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "tfstate" {
  count = var.create_state_bucket ? 1 : 0

  bucket = aws_s3_bucket.tfstate[0].id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "tfstate" {
  count = var.create_state_bucket ? 1 : 0

  bucket = aws_s3_bucket.tfstate[0].id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ── OIDC: GitHub Actions assume roles sem access key estática ──
# O provider é único por conta. Se a Fase 4 já o criou, deixe
# create_oidc_provider = false e o bootstrap reutiliza o existente.
resource "aws_iam_openid_connect_provider" "github" {
  count = var.create_oidc_provider ? 1 : 0

  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]
}

locals {
  oidc_provider_arn = var.create_oidc_provider ? aws_iam_openid_connect_provider.github[0].arn : "arn:aws:iam::${data.aws_caller_identity.current.account_id}:oidc-provider/token.actions.githubusercontent.com"
}

data "aws_iam_policy_document" "github_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [local.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    # Restringe a confiança a este repositório. Sem esta condição,
    # qualquer repositório do GitHub poderia assumir a role.
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = local.repo_subjects
    }
  }
}

# ── Role do Terraform ──
resource "aws_iam_role" "terraform" {
  name               = "${var.role_prefix}-terraform"
  description        = "Role assumida pelo workflow terraform.yml para provisionar a plataforma"
  assume_role_policy = data.aws_iam_policy_document.github_assume_role.json

  # 2h: o destroy — duas passadas mais a limpeza de finalizers — pode passar
  # de 1h, e o token do OIDC expiraria no meio. O apply do EKS cabe em 1h,
  # mas usa o mesmo teto por simplicidade.
  max_session_duration = 7200
}

# Trade-off assumido: provisionar EKS, VPC, RDS e IAM exige permissão ampla.
# Em um ambiente corporativo esta política seria recortada por serviço; aqui a
# proteção efetiva é a condição de trust acima, que limita quem assume a role.
resource "aws_iam_role_policy_attachment" "terraform_admin" {
  role       = aws_iam_role.terraform.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

# ── Role de push no ECR ──
resource "aws_iam_role" "ecr_push" {
  name               = "${var.role_prefix}-ecr-push"
  description        = "Role assumida pelo workflow ci.yml para publicar imagens no ECR"
  assume_role_policy = data.aws_iam_policy_document.github_assume_role.json
}

data "aws_iam_policy_document" "ecr_push" {
  statement {
    effect    = "Allow"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    effect = "Allow"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:CompleteLayerUpload",
      "ecr:InitiateLayerUpload",
      "ecr:PutImage",
      "ecr:UploadLayerPart",
      "ecr:BatchGetImage",
      "ecr:DescribeImages",
    ]
    resources = ["arn:aws:ecr:*:${data.aws_caller_identity.current.account_id}:repository/${var.project}/*"]
  }
}

resource "aws_iam_role_policy" "ecr_push" {
  name   = "ecr-push"
  role   = aws_iam_role.ecr_push.id
  policy = data.aws_iam_policy_document.ecr_push.json
}
