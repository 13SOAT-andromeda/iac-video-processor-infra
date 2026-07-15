terraform {
  required_version = ">= 1.11"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.54"
    }
  }

  backend "s3" {
    key          = "video-processor-infra/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Terraform   = "true"
      Environment = var.environment
      Project     = "video-processor"
    }
  }
}

data "aws_iam_role" "lab_role" {
  name = "LabRole"
}

locals {
  # Fixed cross-repo contract (spec section 4) — NOT the per-environment
  # naming convention used below for the cluster/ECR repo. iac-video-processor-data
  # and iac-video-processor-gateway look this VPC up by this exact tag value.
  vpc_name = "video-processor-vpc"

  cluster_name = "video-processor-eks-${var.environment}"
}
