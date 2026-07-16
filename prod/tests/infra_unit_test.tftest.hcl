mock_provider "aws" {
  mock_data "aws_iam_role" {
    defaults = {
      arn  = "arn:aws:iam::123456789012:role/LabRole"
      name = "LabRole"
    }
  }

  # The ECR module (via aws_iam_policy_document) feeds the mocked provider's
  # auto-generated placeholder values into fields with real format validation
  # (valid JSON). Without this override, `terraform plan` fails before any
  # assert block runs — this isn't a wiring bug in vpc.tf/eks.tf/ecr.tf, it's
  # mock_provider needing valid-shaped inputs for this derived data source.
  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }

  mock_data "aws_partition" {
    defaults = {
      partition          = "aws"
      dns_suffix         = "amazonaws.com"
      reverse_dns_prefix = "com.amazonaws"
    }
  }
}

run "vpc_has_two_azs_and_correct_cidr" {
  command = plan

  assert {
    condition     = local.vpc_cidr == "10.0.0.0/16"
    error_message = "Expected VPC CIDR to be 10.0.0.0/16"
  }

  assert {
    condition     = length(local.azs) == 2
    error_message = "Expected exactly 2 AZs (us-east-1a, us-east-1b)"
  }

  assert {
    condition     = length(local.private_subnet_cidrs) == 2 && length(local.public_subnet_cidrs) == 2
    error_message = "Expected 2 private and 2 public subnet CIDRs (one pair per AZ)"
  }
}

run "vpc_uses_single_shared_nat_gateway" {
  command = plan

  assert {
    condition     = length(module.vpc.natgw_ids) == 1
    error_message = "Expected exactly 1 NAT Gateway (single_nat_gateway = true), not one per AZ"
  }
}

run "cluster_reuses_lab_role_not_a_new_role" {
  command = plan

  assert {
    condition     = local.cluster_name == "video-processor-eks-prod"
    error_message = "Expected cluster name to be video-processor-eks-prod (default environment)"
  }

  assert {
    condition     = data.aws_iam_role.lab_role.arn == "arn:aws:iam::123456789012:role/LabRole"
    error_message = "Expected the mocked data.aws_iam_role.lab_role to resolve to the LabRole ARN that both cluster-level and node-group-level role_arn derive from"
  }

  assert {
    condition     = aws_eks_cluster.this.role_arn == data.aws_iam_role.lab_role.arn
    error_message = "Expected the cluster to reuse LabRole via role_arn instead of a module-created role, since the Academy account lacks iam:CreateRole"
  }

  assert {
    condition     = aws_eks_node_group.users.node_role_arn == data.aws_iam_role.lab_role.arn
    error_message = "Expected the users node group's node_role_arn to reuse data.aws_iam_role.lab_role.arn (the LabRole), not a newly created role"
  }
}

run "node_group_sizing_matches_spec" {
  command = plan

  assert {
    condition     = local.node_group_config.users.instance_types == ["t3.medium"]
    error_message = "Expected the users node group to run on t3.medium"
  }

  assert {
    condition = (
      local.node_group_config.users.min_size == 1 &&
      local.node_group_config.users.max_size == 2 &&
      local.node_group_config.users.desired_size == 1
    )
    error_message = "Expected the users node group to be sized min=1/max=2/desired=1"
  }
}

run "ecr_repository_named_per_environment_convention" {
  command = plan

  assert {
    condition     = module.ecr_users_api.repository_name == "video-processor-users-api-prod"
    error_message = "Expected ECR repository name to follow the video-processor-users-api-${var.environment} convention"
  }
}
