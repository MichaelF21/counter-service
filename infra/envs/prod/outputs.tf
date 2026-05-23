output "cluster_name" {
  value = module.eks.cluster_name
}

output "cluster_endpoint" {
  value = module.eks.cluster_endpoint
}

output "cluster_oidc_provider_arn" {
  value = module.eks.oidc_provider_arn
}

output "ecr_repository_url" {
  value = aws_ecr_repository.counter_service.repository_url
}

output "github_actions_role_arn" {
  description = "Paste this ARN into the GH Actions workflow's role-to-assume input."
  value       = aws_iam_role.github_actions.arn
}

output "vpc_id" {
  value = module.vpc.vpc_id
}

output "private_subnet_ids" {
  value = module.vpc.private_subnets
}

output "kubeconfig_command" {
  description = "Run this on your workstation to point kubectl at the cluster."
  value       = "aws eks update-kubeconfig --name ${module.eks.cluster_name} --region ${var.region}"
}
