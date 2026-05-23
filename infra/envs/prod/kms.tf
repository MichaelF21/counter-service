resource "aws_kms_key" "eks_secrets" {
  description             = "KMS CMK for EKS secret-at-rest encryption (${var.cluster_name})."
  enable_key_rotation     = true
  deletion_window_in_days = 30
  tags                    = var.tags
}

resource "aws_kms_alias" "eks_secrets" {
  name          = "alias/${var.cluster_name}-eks-secrets"
  target_key_id = aws_kms_key.eks_secrets.key_id
}

resource "aws_kms_key" "ebs" {
  description             = "KMS CMK for EBS volume encryption."
  enable_key_rotation     = true
  deletion_window_in_days = 30
  # Policy lives in policies/ebs-kms-key.json.tpl. A customer-managed key
  # blocks the AWS Auto Scaling service-linked role by default; the template
  # restores the minimum grants AWS documents for ASG + EC2 EBS encryption.
  policy = templatefile("${path.module}/policies/ebs-kms-key.json.tpl", {
    account_id = local.account_id
    partition  = local.partition
  })
  tags = var.tags
}

resource "aws_kms_alias" "ebs" {
  name          = "alias/${var.cluster_name}-ebs"
  target_key_id = aws_kms_key.ebs.key_id
}
