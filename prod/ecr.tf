module "ecr_users_api" {
  source  = "terraform-aws-modules/ecr/aws"
  version = "~> 3.2"

  repository_name = "video-processor-users-api-${var.environment}"

  repository_image_tag_mutability = "MUTABLE"
  repository_image_scan_on_push   = true

  repository_lifecycle_policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Keep last 10 images"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = 10
        }
        action = {
          type = "expire"
        }
      }
    ]
  })

  tags = {
    Project     = "video-processor"
    Environment = var.environment
  }
}

module "ecr_authorizer" {
  source  = "terraform-aws-modules/ecr/aws"
  version = "~> 3.2"

  repository_name = "video-processor-authorizer-${var.environment}"

  repository_image_tag_mutability = "MUTABLE"
  repository_image_scan_on_push   = true

  repository_lifecycle_policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Keep last 10 images"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = 10
        }
        action = {
          type = "expire"
        }
      }
    ]
  })

  tags = {
    Project     = "video-processor"
    Environment = var.environment
  }
}

module "ecr_authentication" {
  source  = "terraform-aws-modules/ecr/aws"
  version = "~> 3.2"

  repository_name = "video-processor-authentication-${var.environment}"

  repository_image_tag_mutability = "MUTABLE"
  repository_image_scan_on_push   = true

  repository_lifecycle_policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Keep last 10 images"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = 10
        }
        action = {
          type = "expire"
        }
      }
    ]
  })

  tags = {
    Project     = "video-processor"
    Environment = var.environment
  }
}

module "ecr_worker" {
  source  = "terraform-aws-modules/ecr/aws"
  version = "~> 3.2"

  repository_name = "video-processor-worker-${var.environment}"

  repository_image_tag_mutability = "MUTABLE"
  repository_image_scan_on_push   = true

  repository_lifecycle_policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Keep last 10 images"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = 10
        }
        action = {
          type = "expire"
        }
      }
    ]
  })

  tags = {
    Project     = "video-processor"
    Environment = var.environment
  }
}
