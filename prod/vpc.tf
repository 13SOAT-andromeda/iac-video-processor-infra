locals {
  vpc_cidr = "10.0.0.0/16"
  azs      = ["us-east-1a", "us-east-1b"]

  # Mirrors iac-tech-challenge-infra/modules/vpc/main.tf's cidrsubnet offsets:
  # private subnets get the low block, public subnets are offset by +4.
  private_subnet_cidrs = [for i in range(length(local.azs)) : cidrsubnet(local.vpc_cidr, 8, i)]
  public_subnet_cidrs  = [for i in range(length(local.azs)) : cidrsubnet(local.vpc_cidr, 8, i + 4)]
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 6.6"

  name = local.vpc_name
  cidr = local.vpc_cidr
  azs  = local.azs

  private_subnets = local.private_subnet_cidrs
  public_subnets  = local.public_subnet_cidrs

  enable_nat_gateway = true
  single_nat_gateway = true

  map_public_ip_on_launch = true

  public_subnet_tags = {
    "kubernetes.io/role/elb"                     = "1"
    "kubernetes.io/cluster/${local.cluster_name}" = "shared"
  }

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb"             = "1"
    "kubernetes.io/cluster/${local.cluster_name}" = "shared"
  }

  tags = {
    Project     = "video-processor"
    Environment = var.environment
  }
}
