terraform {
  required_version = ">= 1.11"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.56"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.9"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.35"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.16"
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
  vpc_name = "video-processor-vpc"

  cluster_name = "video-processor-eks-${var.environment}"
}
