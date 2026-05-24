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

# Trust policy and permissions policy live as JSON templates under policies/
# (rendered by templatefile()). Keeps the policies readable as standalone
# IAM docs — easy to grep, easy to lint with cfn-policy-validator/iam-floyd.

resource "aws_iam_role" "github_actions" {
  name = "${var.cluster_name}-gha-ci"
  assume_role_policy = templatefile("${path.module}/policies/github-oidc-assume.json.tpl", {
    github_oidc_provider_arn = data.aws_iam_openid_connect_provider.github.arn
    github_repository        = var.github_repository
  })
  tags = var.tags
}

resource "aws_iam_role_policy" "github_actions" {
  name = "ecr-and-tf-state"
  role = aws_iam_role.github_actions.id
  policy = templatefile("${path.module}/policies/github-actions-inline.json.tpl", {
    ecr_repository_arn  = aws_ecr_repository.counter_service.arn
    state_bucket_arn    = "arn:${local.partition}:s3:::counter-service-tfstate-${local.account_id}-${var.region}"
    state_kms_alias_arn = "arn:${local.partition}:kms:${var.region}:${local.account_id}:alias/counter-service-tfstate"
  })
}

# Scoped permissions for terraform plan/apply, replacing AdministratorAccess.
#
# PowerUserAccess covers every non-IAM action (EKS, EC2/VPC, KMS, ECR, S3,
# CloudWatch, AutoScaling, ELBv2, etc.) — that's the bulk of what the prod
# stack manages.
#
# A second inline policy adds IAM operations, but scoped to:
#   - roles + policies named `${cluster_name}-*` or `AmazonEKS_*` (covers the
#     EKS module's auto-named policies and our own resources)
#   - OIDC providers (account-global, only one for GitHub Actions exists)
#   - service-linked roles (for autoscaling, EKS, ELB)
#
# Net effect: a compromised CI role cannot touch unrelated IAM principals in
# the shared Check Point account — blast radius is bounded to this project.
resource "aws_iam_role_policy_attachment" "github_actions_poweruser" {
  role       = aws_iam_role.github_actions.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/PowerUserAccess"
}

resource "aws_iam_role_policy" "github_actions_iam" {
  name = "iam-scoped"
  role = aws_iam_role.github_actions.id
  policy = templatefile("${path.module}/policies/github-actions-iam.json.tpl", {
    account_id   = local.account_id
    partition    = local.partition
    cluster_name = var.cluster_name
  })
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
