resource "aws_kms_key" "ecr" {
  description             = "KMS CMK for ECR image-layer encryption."
  enable_key_rotation     = true
  deletion_window_in_days = 30
  tags                    = var.tags
}

resource "aws_kms_alias" "ecr" {
  name          = "alias/${var.cluster_name}-ecr"
  target_key_id = aws_kms_key.ecr.key_id
}

resource "aws_ecr_repository" "counter_service" {
  # Account is shared; the bare "counter-service" repo is taken by another
  # candidate. Namespacing by cluster_name keeps us collision-free.
  name                 = var.cluster_name
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "KMS"
    kms_key         = aws_kms_key.ecr.arn
  }

  tags = var.tags
}

# Retain the last 30 immutable tags and expire untagged images quickly.
resource "aws_ecr_lifecycle_policy" "counter_service" {
  repository = aws_ecr_repository.counter_service.name
  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Expire untagged images after 1 day."
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 1
        }
        action = { type = "expire" }
      },
      {
        rulePriority = 2
        description  = "Keep last 30 tagged images."
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = 30
        }
        action = { type = "expire" }
      },
    ]
  })
}
