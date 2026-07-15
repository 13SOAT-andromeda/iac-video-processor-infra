locals {
  # No LabRole in LocalStack — omits create_iam_role/iam_role_arn so the
  # module falls back to its default (create_iam_role = true), unlike
  # prod/eks.tf which pins these to LabRole.
  node_group_config = {
    users = {
      instance_types = ["t3.medium"]
      ami_type       = "AL2023_x86_64_STANDARD"

      min_size     = 1
      max_size     = 2
      desired_size = 1
    }
  }
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.24"

  name               = local.cluster_name
  kubernetes_version = "1.30"

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  endpoint_public_access                   = true
  endpoint_private_access                  = true
  enable_cluster_creator_admin_permissions = true

  enable_irsa = false

  create_kms_key    = false
  encryption_config = null

  eks_managed_node_groups = local.node_group_config

  tags = {
    Project     = "video-processor"
    Environment = var.environment
  }
}
