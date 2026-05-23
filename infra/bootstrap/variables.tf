variable "region" {
  type        = string
  default     = "eu-west-2"
  description = "AWS region for the Terraform state backend."
}

variable "state_bucket_name" {
  type        = string
  description = "Globally unique S3 bucket name for Terraform remote state."
}

variable "tags" {
  type = map(string)
  default = {
    Project   = "counter-service"
    ManagedBy = "Terraform"
    Component = "tf-state-backend"
  }
}
