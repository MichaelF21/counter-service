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

# NOTE: A project-scoped EBS CMK was previously declared here. Using it from
# the EBS CSI driver requires granting both the AutoScaling SLR AND the CSI
# driver's IRSA role on the key policy — substantially more setup than the
# encryption-at-rest requirement actually needs. The gp3 StorageClass now
# uses the AWS-managed `aws/ebs` key (still encrypted at rest, just without
# per-project audit isolation). If/when stronger key isolation is needed,
# bring back the resource + grant the CSI IRSA role + reference its ARN in
# the StorageClass `parameters.kmsKeyId`.
