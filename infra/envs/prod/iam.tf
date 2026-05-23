###############################################################################
# GitHub Actions OIDC: lets GH Actions assume an AWS role without static keys.
###############################################################################

# The GitHub Actions OIDC provider is account-global and already exists in
# this shared Check Point account (likely created by another assignment run).
# We use a data source rather than creating it to avoid the "EntityAlreadyExists"
# collision; trust policies below still reference its ARN.
data "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"
}

data "aws_iam_policy_document" "github_oidc_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [data.aws_iam_openid_connect_provider.github.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      # Scope role assumption to the configured repo's main branch and PR contexts.
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values = [
        "repo:${var.github_repository}:ref:refs/heads/main",
        "repo:${var.github_repository}:pull_request",
        "repo:${var.github_repository}:environment:prod",
      ]
    }
  }
}

resource "aws_iam_role" "github_actions" {
  name               = "${var.cluster_name}-gha-ci"
  assume_role_policy = data.aws_iam_policy_document.github_oidc_assume.json
  tags               = var.tags
}

data "aws_iam_policy_document" "github_actions_inline" {
  statement {
    sid       = "ECRAuth"
    effect    = "Allow"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }
  statement {
    sid    = "ECRPushPull"
    effect = "Allow"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:BatchGetImage",
      "ecr:DescribeImages",
      "ecr:GetDownloadUrlForLayer",
      "ecr:CompleteLayerUpload",
      "ecr:InitiateLayerUpload",
      "ecr:PutImage",
      "ecr:UploadLayerPart",
    ]
    resources = [aws_ecr_repository.counter_service.arn]
  }
  # Terraform state access (used by the `terraform` workflow's plan/apply jobs).
  statement {
    sid       = "TFStateBucketList"
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = ["arn:${local.partition}:s3:::counter-service-tfstate-${local.account_id}-${var.region}"]
  }
  statement {
    sid    = "TFStateObjectRW"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
    ]
    resources = ["arn:${local.partition}:s3:::counter-service-tfstate-${local.account_id}-${var.region}/*"]
  }
  # KMS access for the state bucket's CMK (bootstrap created this key with a
  # known alias).
  statement {
    sid    = "TFStateKMS"
    effect = "Allow"
    actions = [
      "kms:Decrypt",
      "kms:Encrypt",
      "kms:GenerateDataKey",
      "kms:DescribeKey",
    ]
    resources = ["arn:${local.partition}:kms:${var.region}:${local.account_id}:alias/counter-service-tfstate"]
  }
}

resource "aws_iam_role_policy" "github_actions" {
  role   = aws_iam_role.github_actions.id
  policy = data.aws_iam_policy_document.github_actions_inline.json
}

# Terraform plan/apply must refresh every resource in state (EKS, KMS, IAM
# roles, VPC, CloudWatch logs, etc.). For this assignment we attach
# AdministratorAccess to the CI role. In real prod, scope this down via:
#   - per-service Allow policies on resources matching `*counter-service*`
#   - or a Permissions Boundary that caps blast radius
#   - or a SCP at the OU level
resource "aws_iam_role_policy_attachment" "github_actions_admin" {
  role       = aws_iam_role.github_actions.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/AdministratorAccess"
}

###############################################################################
# IRSA: AWS Load Balancer Controller
###############################################################################

module "aws_lbc_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.48"

  role_name                              = "${var.cluster_name}-aws-lbc"
  attach_load_balancer_controller_policy = true

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:aws-load-balancer-controller"]
    }
  }
}

###############################################################################
# IRSA: External Secrets Operator (reads from AWS Secrets Manager).
###############################################################################

module "external_secrets_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.48"

  role_name                             = "${var.cluster_name}-external-secrets"
  attach_external_secrets_policy        = true
  external_secrets_secrets_manager_arns = ["arn:${local.partition}:secretsmanager:${var.region}:${local.account_id}:secret:counter-service/*"]

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["external-secrets:external-secrets"]
    }
  }
}
