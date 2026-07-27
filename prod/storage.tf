data "aws_caller_identity" "current" {}

resource "aws_s3_bucket" "video_processor" {
  bucket = "video-processor-bucket-${var.environment}-${data.aws_caller_identity.current.account_id}"

  tags = {
    Project     = "video-processor"
    Environment = var.environment
  }
}

resource "aws_s3_bucket_notification" "video_processor" {
  bucket = aws_s3_bucket.video_processor.id

  topic {
    topic_arn     = aws_sns_topic.video_upload_events.arn
    events        = ["s3:ObjectCreated:*"]
    filter_suffix = ".mp4"
  }

  depends_on = [aws_sns_topic_policy.video_upload_events]
}

resource "aws_s3_bucket" "artifacts" {
  bucket = "video-processor-artifacts-${var.environment}-${data.aws_caller_identity.current.account_id}"

  tags = {
    Project     = "video-processor"
    Environment = var.environment
  }
}
