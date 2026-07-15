locals {
  # Kept as its own local (rather than inlined in the module call) so the
  # unit test in Task 4 can assert on these values directly — the registry
  # module's own outputs don't re-expose per-node-group sizing inputs.
  node_group_config = {
    users = {
      instance_types = ["t3.medium"]
      ami_type       = "AL2023_x86_64_STANDARD"

      min_size     = 1
      max_size     = 2
      desired_size = 1

      create_iam_role = false
      iam_role_arn    = data.aws_iam_role.lab_role.arn
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

  endpoint_public_access                  = true
  endpoint_private_access                 = true
  enable_cluster_creator_admin_permissions = true

  # AWS Academy: reuse LabRole, module cannot create IAM roles (no iam:CreateRole).
  create_iam_role = false
  iam_role_arn    = data.aws_iam_role.lab_role.arn

  enable_irsa = false

  # create_kms_key = false alone is not enough: encryption_config defaults to
  # {} (non-null), which still enables the cluster's encryption_config block
  # and would try to use a KMS key that doesn't exist. Setting it to null
  # disables the block entirely.
  create_kms_key    = false
  encryption_config = null

  eks_managed_node_groups = local.node_group_config

  tags = {
    Project     = "video-processor"
    Environment = var.environment
  }
}
