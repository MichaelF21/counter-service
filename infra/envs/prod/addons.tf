###############################################################################
# Cluster add-ons via Helm.
#
# Boundary: only "platform" add-ons go here (LBC, metrics-server, ESO, ArgoCD,
# kube-prometheus-stack). Application workloads (counter-service, Redis, future
# Crossplane-managed Postgres) are deployed by Argo CD from the gitops/ dir
# in this repo, so the CD path is a single sync, not two control planes.
###############################################################################

# AWS Load Balancer Controller: provisions the ALBs that satisfy our Ingress.
resource "helm_release" "aws_lbc" {
  name             = "aws-load-balancer-controller"
  repository       = "https://aws.github.io/eks-charts"
  chart            = "aws-load-balancer-controller"
  namespace        = "kube-system"
  version          = "1.9.2"
  create_namespace = false

  set {
    name  = "clusterName"
    value = module.eks.cluster_name
  }
  set {
    name  = "serviceAccount.create"
    value = "true"
  }
  set {
    name  = "serviceAccount.name"
    value = "aws-load-balancer-controller"
  }
  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = module.aws_lbc_irsa.iam_role_arn
  }
  set {
    name  = "region"
    value = var.region
  }
  set {
    name  = "vpcId"
    value = module.vpc.vpc_id
  }

  depends_on = [module.eks]
}

resource "helm_release" "cluster_autoscaler" {
  name             = "cluster-autoscaler"
  repository       = "https://kubernetes.github.io/autoscaler"
  chart            = "cluster-autoscaler"
  namespace        = "kube-system"
  version          = "9.43.2"
  create_namespace = false

  set {
    name  = "autoDiscovery.clusterName"
    value = module.eks.cluster_name
  }
  set {
    name  = "awsRegion"
    value = var.region
  }
  set {
    name  = "rbac.serviceAccount.name"
    value = "cluster-autoscaler"
  }
  set {
    name  = "rbac.serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = module.cluster_autoscaler_irsa.iam_role_arn
  }
  set {
    name  = "extraArgs.balance-similar-node-groups"
    value = "true"
  }
  set {
    name  = "extraArgs.skip-nodes-with-system-pods"
    value = "false"
  }

  depends_on = [module.eks]
}

module "cluster_autoscaler_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.48"

  role_name                        = "${var.cluster_name}-cluster-autoscaler"
  attach_cluster_autoscaler_policy = true
  cluster_autoscaler_cluster_names = [module.eks.cluster_name]

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:cluster-autoscaler"]
    }
  }
}

resource "helm_release" "metrics_server" {
  name       = "metrics-server"
  repository = "https://kubernetes-sigs.github.io/metrics-server/"
  chart      = "metrics-server"
  namespace  = "kube-system"
  version    = "3.12.2"

  set {
    name  = "args"
    value = "{--kubelet-insecure-tls,--kubelet-preferred-address-types=InternalIP\\,Hostname\\,InternalDNS\\,ExternalDNS}"
  }

  depends_on = [module.eks]
}

resource "helm_release" "external_secrets" {
  name             = "external-secrets"
  repository       = "https://charts.external-secrets.io"
  chart            = "external-secrets"
  namespace        = "external-secrets"
  version          = "0.10.5"
  create_namespace = true

  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = module.external_secrets_irsa.iam_role_arn
  }

  depends_on = [module.eks]
}

resource "helm_release" "kube_prometheus_stack" {
  name             = "kube-prometheus-stack"
  repository       = "https://prometheus-community.github.io/helm-charts"
  chart            = "kube-prometheus-stack"
  namespace        = "monitoring"
  version          = "65.5.1"
  create_namespace = true

  values = [yamlencode({
    grafana = {
      adminPassword = "admin"
      service = {
        type = "ClusterIP"
      }
    }
    prometheus = {
      prometheusSpec = {
        # Pick up ServiceMonitors in any namespace tagged with release=kube-prometheus-stack.
        serviceMonitorSelectorNilUsesHelmValues = false
        ruleSelectorNilUsesHelmValues           = false
        podMonitorSelectorNilUsesHelmValues     = false
      }
    }
  })]

  depends_on = [module.eks]
}

resource "helm_release" "argocd" {
  name             = "argocd"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  namespace        = "argocd"
  version          = "7.7.2"
  create_namespace = true

  values = [yamlencode({
    server = {
      service = {
        type = "ClusterIP"
      }
      # Disable TLS at the pod so an internal-only ALB or kubectl port-forward works cleanly.
      extraArgs = ["--insecure"]
    }
    configs = {
      params = {
        "server.insecure" = true
      }
    }
  })]

  depends_on = [module.eks]
}

resource "helm_release" "argocd_image_updater" {
  name       = "argocd-image-updater"
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argocd-image-updater"
  namespace  = "argocd"
  version    = "0.11.0"

  values = [yamlencode({
    config = {
      registries = [{
        name        = "ecr"
        api_url     = "https://${local.account_id}.dkr.ecr.${var.region}.amazonaws.com"
        prefix      = "${local.account_id}.dkr.ecr.${var.region}.amazonaws.com"
        ping        = true
        credentials = "ext:/scripts/ecr-login.sh"
        credexpire  = "10h"
      }]
    }
    # ECR login script: image-updater calls this every 10h to refresh creds via IRSA.
    authScripts = {
      enabled = true
      scripts = {
        "ecr-login.sh" = <<-EOT
          #!/bin/sh
          aws ecr --region ${var.region} get-authorization-token \
            --output text --query 'authorizationData[].authorizationToken' \
            | base64 -d
        EOT
      }
    }
    serviceAccount = {
      annotations = {
        "eks.amazonaws.com/role-arn" = aws_iam_role.argocd_image_updater.arn
      }
    }
  })]

  depends_on = [helm_release.argocd]
}

# IRSA for argocd-image-updater to read ECR.
data "aws_iam_policy_document" "image_updater_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [module.eks.oidc_provider_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "${replace(module.eks.cluster_oidc_issuer_url, "https://", "")}:sub"
      values   = ["system:serviceaccount:argocd:argocd-image-updater"]
    }
  }
}

resource "aws_iam_role" "argocd_image_updater" {
  name               = "${var.cluster_name}-image-updater"
  assume_role_policy = data.aws_iam_policy_document.image_updater_assume.json
  tags               = var.tags
}

resource "aws_iam_role_policy_attachment" "image_updater_ecr_read" {
  role       = aws_iam_role.argocd_image_updater.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}
