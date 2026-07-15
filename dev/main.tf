terraform {
  required_version = ">= 1.11"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.54"
    }
  }

  backend "s3" {
    bucket = "video-processor-bucket-andromeda-local"
    key    = "video-processor-infra/terraform.tfstate"
    region = "us-east-1"
    endpoints = {
      s3       = "http://localhost:4566"
      iam      = "http://localhost:4566"
      sts      = "http://localhost:4566"
      dynamodb = "http://localhost:4566"
    }
    access_key                  = "test"
    secret_key                  = "test"
    skip_credentials_validation = true
    skip_metadata_api_check     = true
    skip_region_validation      = true
    skip_requesting_account_id  = false
    use_path_style              = true
  }
}

provider "aws" {
  region                      = var.region
  access_key                  = "test"
  secret_key                  = "test"
  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_requesting_account_id  = false
  s3_use_path_style           = true

  endpoints {
    ec2            = "http://localhost:4566"
    ecr            = "http://localhost:4566"
    eks            = "http://localhost:4566"
    iam            = "http://localhost:4566"
    sts            = "http://localhost:4566"
    cloudwatchlogs = "http://localhost:4566"
  }

  default_tags {
    tags = {
      Terraform   = "true"
      Environment = var.environment
      Project     = "video-processor"
    }
  }
}

locals {
  # Fixed cross-repo contract (spec section 4) — iac-video-processor-gateway's
  # dev/data.tf already filters on this exact value.
  vpc_name = "video-processor-vpc-local"

  cluster_name = "video-processor-eks-${var.environment}"
}
