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

variable "tags" {
  type = map(string)
  default = {
    Project   = "counter-service"
    ManagedBy = "Terraform"
    Env       = "prod"
  }
}
