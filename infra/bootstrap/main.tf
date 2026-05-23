provider "aws" {
  region = var.region
}

# Customer-managed KMS key encrypts both the state bucket and the lock table.
# A CMK (vs aws/s3) gives us key-rotation control and a per-project audit trail.
resource "aws_kms_key" "state" {
  description             = "KMS key for counter-service Terraform remote state."
  enable_key_rotation     = true
  deletion_window_in_days = 30
  tags                    = var.tags
}

resource "aws_kms_alias" "state" {
  name          = "alias/counter-service-tfstate"
  target_key_id = aws_kms_key.state.key_id
}

resource "aws_s3_bucket" "state" {
  bucket        = var.state_bucket_name
  force_destroy = false
  tags          = var.tags
}

resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.state.arn
    }
    bucket_key_enabled = true
  }
}

# Public Access Block is the AWS default for all new buckets since April 2023.
# This account additionally has an SCP that denies s3:PutBucketPublicAccessBlock,
# so we intentionally don't manage it as TF — the bucket is private by default.

resource "aws_s3_bucket_lifecycle_configuration" "state" {
  bucket = aws_s3_bucket.state.id
  rule {
    id     = "expire-noncurrent"
    status = "Enabled"
    filter {}
    noncurrent_version_expiration {
      noncurrent_days = 90
    }
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

# NOTE: No DynamoDB lock table — Terraform 1.10+ uses S3 conditional writes
# (`.tflock` object) for state locking via `use_lockfile = true` in the prod
# backend. One less resource, no extra cost, same correctness guarantee.
