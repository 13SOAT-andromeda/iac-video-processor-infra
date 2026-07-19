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

# Fila de status de processamento de vídeo (etapa links — arquitetura §6).
# Publicada pelo processing-worker (video-processor-converter) e pelo futuro
# DLQ handler; consumida pelo links-service (video-processor-link-api, pod EKS,
# consumer goroutine contínuo). Nome mantém o contrato da spec de arquitetura
# (video-processing-status-queue) + sufixo de ambiente do repo.
# Sem DLQ própria por decisão de arquitetura (ADR-003, adendo v5): o
# links-service é o dono do estado e trata erros de consumo internamente.
resource "aws_sqs_queue" "video_processing_status" {
  name                       = "video-processing-status-queue-${var.environment}"
  visibility_timeout_seconds = 60

  tags = {
    Project     = "video-processor"
    Environment = var.environment
  }
}

# Fila principal de processamento de vídeo (contrato do video-processor-converter):
# alimentada pela notificação S3 de upload .mp4 (ver storage.tf) e consumida pelo
# processing-worker. Visibility de 20s (vs 1800s em prod) para retries rápidos na
# iteração local; após 3 falhas a mensagem vai para a DLQ, consumida pelo
# dlq-handler. Nomes mantêm o contrato da spec (video-processing-queue /
# video-processing-dlq) + sufixo de ambiente do repo.
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
      Principal = { Service = "s3.amazonaws.com" }
      Action    = "sqs:SendMessage"
      Resource  = aws_sqs_queue.video_processing.arn
      Condition = { ArnEquals = { "aws:SourceArn" = aws_s3_bucket.video_processor.arn } }
    }]
  })
}
