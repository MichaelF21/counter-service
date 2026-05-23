output "state_bucket" {
  value       = aws_s3_bucket.state.bucket
  description = "S3 bucket holding Terraform remote state for the prod environment."
}

output "kms_key_arn" {
  value       = aws_kms_key.state.arn
  description = "KMS CMK used to encrypt state-at-rest."
}
