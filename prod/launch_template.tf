# IMDSv2 hop-limit fix for the EKS worker nodes.
#
# EKS managed node groups launch instances with an IMDS hop limit of 1 by
# default. That only allows the *host* network namespace to reach
# http://169.254.169.254 — a request proxied out of a pod's network
# namespace adds an extra network hop and gets silently dropped. This
# account (AWS Academy Lab) denies iam:CreateRole, so there is no IRSA:
# every pod that needs AWS credentials (including the Datadog Agent
# DaemonSet deployed in datadog.tf) has to fall back to assuming the
# node's LabRole instance profile via IMDS from inside its own pod netns,
# which requires hop_limit = 2.
resource "aws_launch_template" "users" {
  name_prefix = "video-processor-users-${var.environment}-"

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }

  tag_specifications {
    resource_type = "instance"

    tags = {
      Name        = "video-processor-users-${var.environment}"
      Project     = "video-processor"
      Environment = var.environment
    }
  }

  tags = {
    Project     = "video-processor"
    Environment = var.environment
  }

  lifecycle {
    create_before_destroy = true
  }
}
