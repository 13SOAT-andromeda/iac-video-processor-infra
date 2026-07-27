resource "aws_sns_topic" "notification_events" {
  name = "notification-events-topic-${var.environment}"

  tags = {
    Project     = "video-processor"
    Environment = var.environment
  }
}

resource "aws_sqs_queue" "notification_events_dlq" {
  name = "notification-events-queue-${var.environment}-dlq"

  tags = {
    Project     = "video-processor"
    Environment = var.environment
  }
}

resource "aws_sqs_queue" "notification_events" {
  name                       = "notification-events-queue-${var.environment}"
  visibility_timeout_seconds = 180

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.notification_events_dlq.arn
    maxReceiveCount     = 3
  })

  tags = {
    Project     = "video-processor"
    Environment = var.environment
  }
}

resource "aws_sns_topic_subscription" "notification_events" {
  topic_arn = aws_sns_topic.notification_events.arn
  protocol  = "sqs"
  endpoint  = aws_sqs_queue.notification_events.arn
}

resource "aws_sqs_queue_policy" "notification_events" {
  queue_url = aws_sqs_queue.notification_events.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "sns.amazonaws.com" }
      Action    = "sqs:SendMessage"
      Resource  = aws_sqs_queue.notification_events.arn
      Condition = { ArnEquals = { "aws:SourceArn" = aws_sns_topic.notification_events.arn } }
    }]
  })
}

resource "aws_sns_topic" "user_events" {
  name = "video-processor-user-events-topic-${var.environment}"

  tags = {
    Project     = "video-processor"
    Environment = var.environment
  }
}

resource "aws_sqs_queue" "user_events_dlq" {
  name = "video-processor-user-events-queue-${var.environment}-dlq"

  tags = {
    Project     = "video-processor"
    Environment = var.environment
  }
}

resource "aws_sqs_queue" "user_events" {
  name                       = "video-processor-user-events-queue-${var.environment}"
  visibility_timeout_seconds = 60

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.user_events_dlq.arn
    maxReceiveCount     = 3
  })

  tags = {
    Project     = "video-processor"
    Environment = var.environment
  }
}

resource "aws_sns_topic_subscription" "user_events" {
  topic_arn = aws_sns_topic.user_events.arn
  protocol  = "sqs"
  endpoint  = aws_sqs_queue.user_events.arn
}

resource "aws_sqs_queue_policy" "user_events" {
  queue_url = aws_sqs_queue.user_events.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "sns.amazonaws.com" }
      Action    = "sqs:SendMessage"
      Resource  = aws_sqs_queue.user_events.arn
      Condition = { ArnEquals = { "aws:SourceArn" = aws_sns_topic.user_events.arn } }
    }]
  })
}

resource "aws_sqs_queue" "video_processing_status" {
  name                       = "video-processing-status-queue-${var.environment}"
  visibility_timeout_seconds = 60

  tags = {
    Project     = "video-processor"
    Environment = var.environment
  }
}

resource "aws_sqs_queue" "video_processing_dlq" {
  name = "video-processing-dlq-${var.environment}"

  tags = {
    Project     = "video-processor"
    Environment = var.environment
  }
}

resource "aws_sqs_queue" "video_processing" {
  name                       = "video-processing-queue-${var.environment}"
  visibility_timeout_seconds = 20

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.video_processing_dlq.arn
    maxReceiveCount     = 3
  })

  tags = {
    Project     = "video-processor"
    Environment = var.environment
  }
}

resource "aws_sqs_queue_policy" "video_processing" {
  queue_url = aws_sqs_queue.video_processing.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "sns.amazonaws.com" }
      Action    = "sqs:SendMessage"
      Resource  = aws_sqs_queue.video_processing.arn
      Condition = { ArnEquals = { "aws:SourceArn" = aws_sns_topic.video_upload_events.arn } }
    }]
  })
}

resource "aws_sqs_queue" "video_upload_confirmation" {
  name                       = "video-upload-confirmation-queue-${var.environment}"
  visibility_timeout_seconds = 20

  tags = {
    Project     = "video-processor"
    Environment = var.environment
  }
}

resource "aws_sqs_queue_policy" "video_upload_confirmation" {
  queue_url = aws_sqs_queue.video_upload_confirmation.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "sns.amazonaws.com" }
      Action    = "sqs:SendMessage"
      Resource  = aws_sqs_queue.video_upload_confirmation.arn
      Condition = { ArnEquals = { "aws:SourceArn" = aws_sns_topic.video_upload_events.arn } }
    }]
  })
}

resource "aws_sns_topic" "video_upload_events" {
  name = "video-upload-events-topic-${var.environment}"

  tags = {
    Project     = "video-processor"
    Environment = var.environment
  }
}

resource "aws_sns_topic_policy" "video_upload_events" {
  arn = aws_sns_topic.video_upload_events.arn
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "s3.amazonaws.com" }
      Action    = "sns:Publish"
      Resource  = aws_sns_topic.video_upload_events.arn
      Condition = { ArnEquals = { "aws:SourceArn" = aws_s3_bucket.video_processor.arn } }
    }]
  })
}

resource "aws_sns_topic_subscription" "video_upload_events_processing" {
  topic_arn            = aws_sns_topic.video_upload_events.arn
  protocol             = "sqs"
  endpoint             = aws_sqs_queue.video_processing.arn
  raw_message_delivery = true
}

resource "aws_sns_topic_subscription" "video_upload_events_confirmation" {
  topic_arn            = aws_sns_topic.video_upload_events.arn
  protocol             = "sqs"
  endpoint             = aws_sqs_queue.video_upload_confirmation.arn
  raw_message_delivery = true
}
