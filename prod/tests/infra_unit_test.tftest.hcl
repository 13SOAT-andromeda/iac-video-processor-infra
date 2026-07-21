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

  mock_data "aws_eks_cluster_auth" {
    defaults = {
      token = "mock-token"
    }
  }
}

# datadog.tf declares the kubernetes/helm providers at root module level, so
# every run block in this file (which plans the whole prod/ module) needs
# them mocked too — otherwise Terraform tries to configure real providers.
mock_provider "kubernetes" {}
mock_provider "helm" {}

variables {
  datadog_api_key = "mock-api-key"
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

run "node_group_launch_template_raises_imds_hop_limit" {
  command = plan

  # Pods run one network hop further from 169.254.169.254 than the node
  # itself. Without a hop limit of at least 2, the AWS SDK inside a pod
  # fails with "no EC2 IMDS role found" trying to inherit the node's IAM
  # role (LabRole) — there's no IRSA available in this Academy account to
  # fall back on (no iam:CreateRole).
  assert {
    condition     = aws_launch_template.users_node.metadata_options[0].http_put_response_hop_limit == 2
    error_message = "Expected the users node launch template to set http_put_response_hop_limit = 2 so pods can reach the EC2 metadata service"
  }

  assert {
    condition     = aws_launch_template.users_node.metadata_options[0].http_tokens == "required"
    error_message = "Expected IMDSv2 to be required (http_tokens = required), not just optional"
  }

  assert {
    condition     = length(aws_eks_node_group.users.launch_template) == 1
    error_message = "Expected the users node group to reference the custom launch template instead of using EKS's auto-generated default"
  }
}

run "ecr_repository_named_per_environment_convention" {
  command = plan

  assert {
    condition     = module.ecr_users_api.repository_name == "video-processor-users-api-prod"
    error_message = "Expected ECR repository name to follow the video-processor-users-api-${var.environment} convention"
  }

  assert {
    condition     = module.ecr_link_api.repository_name == "video-processor-link-api-prod"
    error_message = "Expected ECR repository name to follow the video-processor-link-api-${var.environment} convention"
  }
}

run "video_processing_status_queue_has_no_dlq_per_adr003" {
  command = plan

  assert {
    condition     = aws_sqs_queue.video_processing_status.name == "video-processing-status-queue-prod"
    error_message = "Expected the status queue to keep the architecture-spec contract name video-processing-status-queue + environment suffix"
  }

  # Note: the queue deliberately has NO redrive_policy/DLQ (ADR-003 v5
  # addendum — links-service owns the state and handles consume errors
  # internally). redrive_policy is Optional+Computed, so its absence cannot
  # be asserted at plan time without an override that would defeat the check.

  assert {
    condition     = aws_sqs_queue.video_processing_status.visibility_timeout_seconds == 60
    error_message = "Expected a 60s visibility timeout — links-service applies a fast idempotent DynamoDB transition per message"
  }
}

run "notification_events_pair_named_and_wired_per_spec" {
  command = plan

  # aws_sns_topic.arn / aws_sqs_queue.arn are Computed-only attributes: for a
  # resource being created (not yet in state), the real AWS provider leaves
  # them "known after apply", so command = plan alone can't resolve any
  # assertion that reaches through them (redrive_policy's deadLetterTargetArn,
  # the SNS subscription's endpoint, or the queue policy's SourceArn
  # condition — all reference some other resource's .arn). override_resource
  # with override_during = plan supplies a known arn for just these three
  # resources, scoped to this run block only, so the plan-phase graph can
  # resolve the derived values below without touching the shared
  # mock_provider block or any other run block.
  override_resource {
    target = aws_sns_topic.notification_events
    values = {
      arn = "arn:aws:sns:us-east-1:123456789012:notification-events-topic-prod"
    }
    override_during = plan
  }

  override_resource {
    target = aws_sqs_queue.notification_events
    values = {
      arn = "arn:aws:sqs:us-east-1:123456789012:notification-events-queue-prod"
    }
    override_during = plan
  }

  override_resource {
    target = aws_sqs_queue.notification_events_dlq
    values = {
      arn = "arn:aws:sqs:us-east-1:123456789012:notification-events-queue-prod-dlq"
    }
    override_during = plan
  }

  assert {
    condition     = aws_sns_topic.notification_events.name == "notification-events-topic-prod"
    error_message = "Expected the notification SNS topic to be project-agnostic (no video-processor- prefix), per ADR-012"
  }

  assert {
    condition     = aws_sqs_queue.notification_events.name == "notification-events-queue-prod"
    error_message = "Expected the notification SQS queue name to match the notification-events-queue-${var.environment} convention"
  }

  assert {
    condition     = aws_sqs_queue.notification_events_dlq.name == "notification-events-queue-prod-dlq"
    error_message = "Expected the notification DLQ name to be the main queue name with a -dlq suffix"
  }

  assert {
    condition     = aws_sqs_queue.notification_events.visibility_timeout_seconds == 180
    error_message = "Expected the notification queue visibility timeout to be 180s (6x the 30s consumer Lambda timeout)"
  }

  assert {
    condition     = jsondecode(aws_sqs_queue.notification_events.redrive_policy).deadLetterTargetArn == aws_sqs_queue.notification_events_dlq.arn
    error_message = "Expected the notification queue's redrive_policy to point at its own DLQ arn, not some other queue"
  }

  assert {
    condition     = jsondecode(aws_sqs_queue.notification_events.redrive_policy).maxReceiveCount == 3
    error_message = "Expected maxReceiveCount to be 3 for the notification queue's redrive policy"
  }

  assert {
    condition     = aws_sns_topic_subscription.notification_events.endpoint == aws_sqs_queue.notification_events.arn
    error_message = "Expected the notification SNS subscription to point at the notification SQS queue, not a different queue"
  }

  assert {
    condition     = jsondecode(aws_sqs_queue_policy.notification_events.policy).Statement[0].Condition.ArnEquals["aws:SourceArn"] == aws_sns_topic.notification_events.arn
    error_message = "Expected the notification queue policy to scope SendMessage to its own topic's arn via aws:SourceArn"
  }
}

run "user_events_pair_named_and_wired_per_spec" {
  command = plan

  # Same plan-time unknown-arn issue as the notification_events run block
  # above — see the comment there for why these overrides are needed.
  override_resource {
    target = aws_sns_topic.user_events
    values = {
      arn = "arn:aws:sns:us-east-1:123456789012:video-processor-user-events-topic-prod"
    }
    override_during = plan
  }

  override_resource {
    target = aws_sqs_queue.user_events
    values = {
      arn = "arn:aws:sqs:us-east-1:123456789012:video-processor-user-events-queue-prod"
    }
    override_during = plan
  }

  override_resource {
    target = aws_sqs_queue.user_events_dlq
    values = {
      arn = "arn:aws:sqs:us-east-1:123456789012:video-processor-user-events-queue-prod-dlq"
    }
    override_during = plan
  }

  assert {
    condition     = aws_sns_topic.user_events.name == "video-processor-user-events-topic-prod"
    error_message = "Expected the user-events SNS topic to keep the video-processor- prefix (project-specific domain event), per ADR-012"
  }

  assert {
    condition     = aws_sqs_queue.user_events.name == "video-processor-user-events-queue-prod"
    error_message = "Expected the user-events SQS queue name to match the video-processor-user-events-queue-${var.environment} convention"
  }

  assert {
    condition     = aws_sqs_queue.user_events_dlq.name == "video-processor-user-events-queue-prod-dlq"
    error_message = "Expected the user-events DLQ name to be the main queue name with a -dlq suffix"
  }

  assert {
    condition     = aws_sqs_queue.user_events.visibility_timeout_seconds == 60
    error_message = "Expected the user-events queue visibility timeout to be 60s (worker does a single idempotent INSERT)"
  }

  assert {
    condition     = jsondecode(aws_sqs_queue.user_events.redrive_policy).deadLetterTargetArn == aws_sqs_queue.user_events_dlq.arn
    error_message = "Expected the user-events queue's redrive_policy to point at its own DLQ arn, not some other queue"
  }

  assert {
    condition     = aws_sns_topic_subscription.user_events.endpoint == aws_sqs_queue.user_events.arn
    error_message = "Expected the user-events SNS subscription to point at the user-events SQS queue, not a different queue"
  }

  assert {
    condition     = jsondecode(aws_sqs_queue_policy.user_events.policy).Statement[0].Condition.ArnEquals["aws:SourceArn"] == aws_sns_topic.user_events.arn
    error_message = "Expected the user-events queue policy to scope SendMessage to its own topic's arn via aws:SourceArn"
  }
}

run "video_processing_pipeline_wired_per_converter_contract" {
  command = plan

  # Same plan-time unknown-arn issue as the notification_events run block
  # above — see the comment there for why these overrides are needed.
  override_resource {
    target = aws_sqs_queue.video_processing
    values = {
      arn = "arn:aws:sqs:us-east-1:123456789012:video-processing-queue-prod"
    }
    override_during = plan
  }

  override_resource {
    target = aws_sqs_queue.video_processing_dlq
    values = {
      arn = "arn:aws:sqs:us-east-1:123456789012:video-processing-dlq-prod"
    }
    override_during = plan
  }

  override_resource {
    target = aws_s3_bucket.video_processor
    values = {
      arn = "arn:aws:s3:::video-processor-bucket-prod"
    }
    override_during = plan
  }

  assert {
    condition     = startswith(aws_s3_bucket.video_processor.bucket, "video-processor-bucket-prod-")
    error_message = "Expected the video bucket to follow the video-processor-bucket-$${var.environment}-$${account_id} convention (account_id suffix avoids the global S3 namespace collision hit across AWS Academy Lab accounts)"
  }

  assert {
    condition     = aws_sqs_queue.video_processing.name == "video-processing-queue-prod"
    error_message = "Expected the main queue to keep the converter contract name video-processing-queue + environment suffix"
  }

  assert {
    condition     = aws_sqs_queue.video_processing_dlq.name == "video-processing-dlq-prod"
    error_message = "Expected the DLQ to keep the converter contract name video-processing-dlq + environment suffix"
  }

  assert {
    condition     = aws_sqs_queue.video_processing.visibility_timeout_seconds == 1800
    error_message = "Expected a 1800s visibility timeout — the processing-worker runs ffmpeg on potentially long videos"
  }

  assert {
    condition     = jsondecode(aws_sqs_queue.video_processing.redrive_policy).deadLetterTargetArn == aws_sqs_queue.video_processing_dlq.arn
    error_message = "Expected the main queue's redrive_policy to point at its own DLQ arn, not some other queue"
  }

  assert {
    condition     = jsondecode(aws_sqs_queue.video_processing.redrive_policy).maxReceiveCount == 3
    error_message = "Expected maxReceiveCount to be 3 for the main queue's redrive policy"
  }

  assert {
    condition     = jsondecode(aws_sqs_queue_policy.video_processing.policy).Statement[0].Condition.ArnEquals["aws:SourceArn"] == aws_s3_bucket.video_processor.arn
    error_message = "Expected the main queue policy to scope S3 SendMessage to the video bucket's arn via aws:SourceArn"
  }

  assert {
    condition     = aws_s3_bucket_notification.video_processor.queue[0].queue_arn == aws_sqs_queue.video_processing.arn
    error_message = "Expected the S3 notification to target the main video-processing queue"
  }

  assert {
    condition     = aws_s3_bucket_notification.video_processor.queue[0].filter_suffix == ".mp4"
    error_message = "Expected the S3 notification to filter on .mp4 so the processed/ zip does not re-trigger the worker"
  }
}

run "worker_ecr_and_artifacts_bucket_named_per_convention" {
  command = plan

  assert {
    condition     = module.ecr_worker.repository_name == "video-processor-worker-prod"
    error_message = "Expected the worker ECR repository name to follow the video-processor-worker-${var.environment} convention (the converter's deploy.yml pushes to this name)"
  }

  assert {
    condition     = startswith(aws_s3_bucket.artifacts.bucket, "video-processor-artifacts-prod-")
    error_message = "Expected the deploy-artifacts bucket to follow the video-processor-artifacts-$${var.environment}-$${account_id} convention (the converter's CD uploads dlq-handler zips here)"
  }
}

run "jwt_signing_key_secret_named_and_wired_per_spec" {
  command = plan

  override_resource {
    target = random_password.jwt_signing_key
    values = {
      result = "mock-generated-password-value"
    }
    override_during = plan
  }

  assert {
    condition     = aws_secretsmanager_secret.jwt_signing_key.name == "jwt-signing-key-prod"
    error_message = "Expected the JWT signing key secret name to follow the jwt-signing-key-${var.environment} convention"
  }

  assert {
    condition     = random_password.jwt_signing_key.length == 64
    error_message = "Expected the generated JWT signing key to be 64 characters long"
  }

  assert {
    condition     = aws_secretsmanager_secret_version.jwt_signing_key.secret_string == "mock-generated-password-value"
    error_message = "Expected the secret version to store the random_password-generated value, not a hardcoded string"
  }
}
