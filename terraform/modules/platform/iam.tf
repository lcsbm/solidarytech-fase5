locals {
  k8s_namespace = "solidarytech"
}

# ── EBS CSI Driver (obrigatorio no EKS 1.27+ para PersistentVolumes) ──
module "ebs_csi_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.39"

  role_name             = "${local.name_prefix}-ebs-csi"
  attach_ebs_csi_policy = true

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:ebs-csi-controller-sa"]
    }
  }

  tags = local.common_tags
}

# ── External Secrets Operator: le as secrets do Secrets Manager ──
module "external_secrets_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.39"

  role_name = "${local.name_prefix}-external-secrets"

  attach_external_secrets_policy        = true
  external_secrets_ssm_parameter_arns   = ["arn:aws:ssm:*:*:parameter/${var.project}/*"]
  external_secrets_secrets_manager_arns = ["arn:aws:secretsmanager:*:*:secret:${var.project}/*"]

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["external-secrets:external-secrets"]
    }
  }

  tags = local.common_tags
}

# ── volunteer-service: acesso a tabela DynamoDB ──
data "aws_iam_policy_document" "volunteer_dynamodb" {
  statement {
    effect = "Allow"
    actions = [
      "dynamodb:PutItem",
      "dynamodb:GetItem",
      "dynamodb:Query",
      "dynamodb:Scan",
      "dynamodb:UpdateItem",
      "dynamodb:DeleteItem",
      "dynamodb:DescribeTable",
    ]
    resources = [
      aws_dynamodb_table.volunteers.arn,
      "${aws_dynamodb_table.volunteers.arn}/index/*",
    ]
  }
}

resource "aws_iam_policy" "volunteer_dynamodb" {
  name        = "${local.name_prefix}-volunteer-dynamodb"
  description = "Acesso do volunteer-service a tabela DynamoDB de voluntarios"
  policy      = data.aws_iam_policy_document.volunteer_dynamodb.json

  tags = local.common_tags
}

module "volunteer_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.39"

  role_name = "${local.name_prefix}-volunteer-service"

  role_policy_arns = {
    dynamodb = aws_iam_policy.volunteer_dynamodb.arn
  }

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["${local.k8s_namespace}:volunteer-service"]
    }
  }

  tags = local.common_tags
}

# ── donation-service: publica eventos na fila SQS ──
data "aws_iam_policy_document" "donation_sqs" {
  statement {
    effect = "Allow"
    actions = [
      "sqs:SendMessage",
      "sqs:GetQueueAttributes",
      "sqs:GetQueueUrl",
    ]
    resources = [aws_sqs_queue.donations.arn]
  }
}

resource "aws_iam_policy" "donation_sqs" {
  name        = "${local.name_prefix}-donation-sqs"
  description = "Permite ao donation-service publicar eventos de doacao no SQS"
  policy      = data.aws_iam_policy_document.donation_sqs.json

  tags = local.common_tags
}

module "donation_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.39"

  role_name = "${local.name_prefix}-donation-service"

  role_policy_arns = {
    sqs = aws_iam_policy.donation_sqs.arn
  }

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["${local.k8s_namespace}:donation-service"]
    }
  }

  tags = local.common_tags
}
