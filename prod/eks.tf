locals {
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


resource "aws_eks_cluster" "this" {
  name     = local.cluster_name
  role_arn = data.aws_iam_role.lab_role.arn
  version  = "1.31"

  access_config {
    authentication_mode                         = "API"
    bootstrap_cluster_creator_admin_permissions = true
  }

  vpc_config {
    subnet_ids              = module.vpc.private_subnets
    endpoint_public_access  = true
    endpoint_private_access = true
  }

  tags = {
    Project     = "video-processor"
    Environment = var.environment
  }
}

resource "aws_eks_node_group" "users" {
  cluster_name    = aws_eks_cluster.this.name
  node_group_name = "video-processor-users-${var.environment}"
  node_role_arn   = data.aws_iam_role.lab_role.arn
  subnet_ids      = module.vpc.private_subnets
  version         = aws_eks_cluster.this.version

  instance_types = local.node_group_config.users.instance_types
  ami_type       = local.node_group_config.users.ami_type

  # See prod/launch_template.tf — sets the IMDSv2 hop limit to 2 so pods
  # (e.g. the Datadog Agent) can reach IMDS and assume LabRole.
  launch_template {
    id      = aws_launch_template.users.id
    version = aws_launch_template.users.latest_version
  }

  scaling_config {
    min_size     = local.node_group_config.users.min_size
    max_size     = local.node_group_config.users.max_size
    desired_size = local.node_group_config.users.desired_size
  }

  tags = {
    Project     = "video-processor"
    Environment = var.environment
  }
}
