module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.31"

  cluster_name    = var.cluster_name
  cluster_version = var.kubernetes_version

  # ASSIGNMENT HARD REQUIREMENT: support_type must be STANDARD.
  # The EXTENDED option triggers Access Denied on this Check Point AWS account.
  cluster_upgrade_policy = {
    support_type = "STANDARD"
  }

  vpc_id                          = module.vpc.vpc_id
  subnet_ids                      = module.vpc.private_subnets
  control_plane_subnet_ids        = module.vpc.private_subnets
  cluster_endpoint_public_access  = true
  cluster_endpoint_private_access = true

  # Secret-at-rest encryption with our CMK.
  cluster_encryption_config = {
    resources        = ["secrets"]
    provider_key_arn = aws_kms_key.eks_secrets.arn
  }

  # CloudWatch log types we need for audit + troubleshooting.
  cluster_enabled_log_types = ["api", "audit", "authenticator"]

  # IRSA on by default in module v20+; OIDC provider is created.
  enable_irsa = true

  # Both principals that might run terraform need EKS API access via access
  # entries (avoids the legacy aws-auth ConfigMap). We DON'T set
  # `enable_cluster_creator_admin_permissions = true` because that creates an
  # entry under a fixed `cluster_creator` key bound to whoever applies first
  # — CI and a local operator would then conflict on that key. Enumerating
  # both principals explicitly works around it.
  authentication_mode = "API"

  access_entries = {
    bootstrap_admin = {
      principal_arn = var.bootstrap_admin_arn
      policy_associations = {
        admin = {
          policy_arn = "arn:${local.partition}:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
          access_scope = {
            type = "cluster"
          }
        }
      }
    }
    github_actions = {
      principal_arn = aws_iam_role.github_actions.arn
      policy_associations = {
        admin = {
          policy_arn = "arn:${local.partition}:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
          access_scope = {
            type = "cluster"
          }
        }
      }
    }
  }

  cluster_addons = {
    coredns = {
      most_recent = true
    }
    kube-proxy = {
      most_recent = true
    }
    vpc-cni = {
      most_recent = true
      # In VPC CNI v1.14+ the network-policy toggle moved out of env into
      # top-level config; node-agent must also be enabled to enforce policies.
      configuration_values = jsonencode({
        enableNetworkPolicy = "true"
        nodeAgent = {
          enabled = true
        }
        env = {
          ENABLE_POD_ENI           = "true"
          ENABLE_PREFIX_DELEGATION = "true"
        }
      })
    }
    aws-ebs-csi-driver = {
      most_recent              = true
      service_account_role_arn = module.ebs_csi_irsa.iam_role_arn
    }
  }

  eks_managed_node_group_defaults = {
    ami_type       = "AL2023_x86_64_STANDARD"
    instance_types = var.node_instance_types
    capacity_type  = "ON_DEMAND"

    block_device_mappings = {
      xvda = {
        device_name = "/dev/xvda"
        ebs = {
          volume_size = 50
          volume_type = "gp3"
          encrypted   = true
          # AWS-managed alias/aws/ebs (default when kms_key_id is omitted).
          # See kms.tf for the rationale.
          delete_on_termination = true
        }
      }
    }
  }

  eks_managed_node_groups = {
    default = {
      desired_size = var.node_desired_size
      min_size     = var.node_min_size
      max_size     = var.node_max_size

      labels = {
        role = "default"
      }
      tags = {
        "karpenter.sh/discovery" = var.cluster_name
      }
    }
  }

  tags = var.tags
}

# IRSA role for the EBS CSI driver — needed because the cluster_addon above
# references it. Module manages the trust policy against the cluster's OIDC.
module "ebs_csi_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.48"

  role_name             = "${var.cluster_name}-ebs-csi"
  attach_ebs_csi_policy = true

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:ebs-csi-controller-sa"]
    }
  }
}

# gp3 default storage class — CMK-encrypted, expandable. Marks gp2 non-default.
resource "kubernetes_storage_class_v1" "gp3" {
  metadata {
    name = "gp3"
    annotations = {
      "storageclass.kubernetes.io/is-default-class" = "true"
    }
  }
  storage_provisioner    = "ebs.csi.aws.com"
  reclaim_policy         = "Delete"
  volume_binding_mode    = "WaitForFirstConsumer"
  allow_volume_expansion = true

  parameters = {
    type      = "gp3"
    encrypted = "true"
    # AWS-managed `alias/aws/ebs` is used by default when kmsKeyId is omitted.
    # We started with a project-scoped CMK but its key policy needs explicit
    # grants for both the AutoScaling SLR and the EBS CSI driver IRSA role —
    # the latter blocks volume create/attach with a quiet retry loop.
    # Trade-off: less per-project audit isolation, no rotation control; but
    # the assignment requirement (encryption at rest) is satisfied either way.
    fsType = "ext4"
  }

  depends_on = [module.eks]
}

resource "kubernetes_annotations" "gp2_non_default" {
  api_version = "storage.k8s.io/v1"
  kind        = "StorageClass"
  metadata {
    name = "gp2"
  }
  annotations = {
    "storageclass.kubernetes.io/is-default-class" = "false"
  }
  force      = true
  depends_on = [module.eks]
}
