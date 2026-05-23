variable "region" {
  type    = string
  default = "eu-west-2"
}

variable "project" {
  type    = string
  default = "counter-service"
}

variable "cluster_name" {
  type    = string
  default = "counter-service-prod"
}

variable "kubernetes_version" {
  type = string
  # 1.34 is in EKS Standard Support through ~Nov 2026.
  # The assignment forbids Extended Support (Access Denied on this account),
  # so we must stay on a version still in Standard Support at apply time.
  default = "1.34"
}

variable "vpc_cidr" {
  type    = string
  default = "10.42.0.0/16"
}

variable "node_instance_types" {
  type    = list(string)
  default = ["t3.medium"]
}

variable "node_desired_size" {
  type    = number
  default = 2
}

variable "node_min_size" {
  type    = number
  default = 2
}

variable "node_max_size" {
  type    = number
  default = 6
}

variable "github_repository" {
  type        = string
  description = "GitHub repo allowed to assume the CI role (owner/repo)."
  default     = "MichaelF21/counter-service"
}

# Human admin who needs kubectl-level access to the cluster. Kept as an IAM
# user ARN (not an assumed-role ARN) so EKS access entry creation succeeds
# from any caller — including CI, where data.aws_caller_identity.current.arn
# would resolve to an assumed-role ARN that EKS rejects.
variable "bootstrap_admin_arn" {
  type        = string
  default     = "arn:aws:iam::630943284793:user/michaelfeldman8@gmail.com"
  description = "IAM user/role ARN granted cluster-admin via EKS access entry."
}

variable "tags" {
  type = map(string)
  default = {
    Project   = "counter-service"
    ManagedBy = "Terraform"
    Env       = "prod"
  }
}
