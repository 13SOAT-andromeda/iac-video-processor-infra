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
# alimentada pela notificação S3 de upload .mp4 (ver storage.tf, via SNS
# fan-out video_upload_events) e consumida pelo processing-worker. Visibility
# de 1800s cobre o processamento ffmpeg; após 3 falhas a mensagem vai para a
# DLQ, consumida pelo dlq-handler. Nomes mantêm o contrato da spec
# (video-processing-queue / video-processing-dlq) + sufixo de ambiente do repo.
resource "aws_sqs_queue" "video_processing_dlq" {
  name = "video-processing-dlq-${var.environment}"

  tags = {
    Project     = "video-processor"
    Environment = var.environment
  }
}

resource "aws_sqs_queue" "video_processing" {
  name                       = "video-processing-queue-${var.environment}"
  visibility_timeout_seconds = 1800

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

# Fila de confirmação de upload (etapa links): o links-service consome pra
# transicionar UPLOAD_PENDING -> UPLOAD_COMPLETED -> PROCESSING_PENDING
# assim que o S3 confirma a gravação do arquivo bruto — substitui o antigo
# callback HTTP (PUT /links/:id/upload) que dependia do frontend notificar o
# backend depois do upload. Mesmo evento S3 que alimenta video_processing
# acima, via fan-out do tópico video_upload_events (dois consumidores
# independentes do mesmo ObjectCreated). Sem DLQ própria, mesma decisão de
# arquitetura da video_processing_status (ADR-003, adendo v5): o
# links-service trata erros de consumo internamente (evento é idempotente).
resource "aws_sqs_queue" "video_upload_confirmation" {
  name                       = "video-upload-confirmation-queue-${var.environment}"
  visibility_timeout_seconds = 60

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

# Tópico de fan-out do evento de upload bruto (S3 ObjectCreated, filtro
# .mp4 — ver storage.tf): S3 só permite um destino não-ambíguo por
# regra de notificação, então em vez de duas filas SQS competindo pelo
# mesmo filtro de sufixo, o bucket notifica este tópico único e ele
# replica a mensagem pras duas filas abaixo (video_processing pro worker,
# video_upload_confirmation pro links-service).
resource "aws_sns_topic" "video_upload_events" {
  name = "video-upload-events-topic-${var.environment}"

  tags = {
    Project     = "video-processor"
    Environment = var.environment
  }
}

# S3 precisa de permissão explícita de Publish no tópico antes de aceitar a
# notification config em storage.tf (senão o PutBucketNotificationConfiguration
# falha com "Unable to validate the following destination configurations").
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
  topic_arn = aws_sns_topic.video_upload_events.arn
  protocol  = "sqs"
  endpoint  = aws_sqs_queue.video_processing.arn
}

resource "aws_sns_topic_subscription" "video_upload_events_confirmation" {
  topic_arn = aws_sns_topic.video_upload_events.arn
  protocol  = "sqs"
  endpoint  = aws_sqs_queue.video_upload_confirmation.arn
}
