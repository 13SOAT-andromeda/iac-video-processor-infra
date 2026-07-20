output "vpc_id" {
  description = "The ID of the VPC"
  value       = module.vpc.vpc_id
}

output "cluster_name" {
  description = "The name of the EKS cluster"
  value       = module.eks.cluster_name
}

output "users_api_ecr_repository_url" {
  description = "The ECR repository URL for video-processor-users-api"
  value       = module.ecr_users_api.repository_url
}

output "notification_events_topic_arn" {
  description = "ARN of the notification-events SNS topic (consumed by video-processor-authentication-api)"
  value       = aws_sns_topic.notification_events.arn
}

output "user_events_topic_arn" {
  description = "ARN of the video-processor-user-events SNS topic (consumed by video-processor-authentication-api)"
  value       = aws_sns_topic.user_events.arn
}

output "user_events_queue_arn" {
  description = "ARN of the video-processor-user-events SQS queue (consumed by video-processor-users-api's worker)"
  value       = aws_sqs_queue.user_events.arn
}

output "link_api_ecr_repository_url" {
  description = "The ECR repository URL for video-processor-link-api"
  value       = module.ecr_link_api.repository_url
}

output "video_processing_status_queue_url" {
  description = "URL of the video-processing-status SQS queue (published by converter/DLQ handler, consumed by links-service)"
  value       = aws_sqs_queue.video_processing_status.id
}

output "video_processing_status_queue_arn" {
  description = "ARN of the video-processing-status SQS queue"
  value       = aws_sqs_queue.video_processing_status.arn
}

output "jwt_signing_key_secret_arn" {
  description = "ARN of the jwt-signing-key secret (shared between authentication-api, authorizer, and users-api)"
  value       = aws_secretsmanager_secret.jwt_signing_key.arn
}

output "jwt_signing_key_secret_name" {
  description = "Name of the jwt-signing-key secret, for cross-repo lookup via data.aws_secretsmanager_secret"
  value       = aws_secretsmanager_secret.jwt_signing_key.name
}
