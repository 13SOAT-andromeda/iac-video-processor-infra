output "vpc_id" {
  description = "The ID of the VPC"
  value       = module.vpc.vpc_id
}

output "cluster_name" {
  description = "The name of the EKS cluster"
  value       = aws_eks_cluster.this.name
}

output "cluster_endpoint" {
  description = "The EKS cluster API server endpoint"
  value       = aws_eks_cluster.this.endpoint
}

output "users_api_ecr_repository_url" {
  description = "The ECR repository URL for video-processor-users-api"
  value       = module.ecr_users_api.repository_url
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

output "datadog_agent_helm_release_status" {
  description = "Status of the Datadog Agent Helm release (deployed, failed, etc.)"
  value       = helm_release.datadog.status
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

output "jwt_signing_key_secret_arn" {
  description = "ARN of the jwt-signing-key secret (shared between authentication-api, authorizer, and users-api)"
  value       = aws_secretsmanager_secret.jwt_signing_key.arn
}

output "jwt_signing_key_secret_name" {
  description = "Name of the jwt-signing-key secret, for cross-repo lookup via data.aws_secretsmanager_secret"
  value       = aws_secretsmanager_secret.jwt_signing_key.name
}

output "video_processor_bucket_name" {
  description = "Name of the S3 bucket for raw video uploads and processed frame zips"
  value       = aws_s3_bucket.video_processor.bucket
}

output "video_processing_queue_url" {
  description = "URL of the main video-processing SQS queue (fed by S3 notifications, consumed by the processing-worker)"
  value       = aws_sqs_queue.video_processing.id
}

output "video_processing_queue_arn" {
  description = "ARN of the main video-processing SQS queue"
  value       = aws_sqs_queue.video_processing.arn
}

output "video_processing_dlq_url" {
  description = "URL of the video-processing DLQ (consumed by the dlq-handler)"
  value       = aws_sqs_queue.video_processing_dlq.id
}

output "video_processing_dlq_arn" {
  description = "ARN of the video-processing DLQ"
  value       = aws_sqs_queue.video_processing_dlq.arn
}

output "worker_ecr_repository_url" {
  description = "The ECR repository URL for the video-processor-worker Lambda image"
  value       = module.ecr_worker.repository_url
}

output "artifacts_bucket_name" {
  description = "Name of the deploy-artifacts S3 bucket (dlq-handler zips published by the converter CD)"
  value       = aws_s3_bucket.artifacts.bucket
}

output "video_upload_confirmation_queue_url" {
  description = "URL of the video-upload-confirmation SQS queue (fed by S3 ObjectCreated via SNS fan-out, consumed by links-service to auto-confirm uploads)"
  value       = aws_sqs_queue.video_upload_confirmation.id
}

output "video_upload_confirmation_queue_arn" {
  description = "ARN of the video-upload-confirmation SQS queue"
  value       = aws_sqs_queue.video_upload_confirmation.arn
}

output "video_upload_events_topic_arn" {
  description = "ARN of the video-upload-events SNS topic (S3 ObjectCreated fan-out to video_processing and video_upload_confirmation)"
  value       = aws_sns_topic.video_upload_events.arn
}
