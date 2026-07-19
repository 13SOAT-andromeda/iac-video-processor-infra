# Bucket de vídeos (contrato do video-processor-converter): uploads .mp4 disparam
# a fila principal; o worker grava o .zip de frames em processed/. O filtro por
# sufixo .mp4 evita que o .zip gerado re-dispare o worker (que também se protege
# via ErrNotRawKey).
resource "aws_s3_bucket" "video_processor" {
  bucket = "video-processor-bucket-${var.environment}"

  tags = {
    Project     = "video-processor"
    Environment = var.environment
  }
}

resource "aws_s3_bucket_notification" "video_processor" {
  bucket = aws_s3_bucket.video_processor.id

  queue {
    queue_arn     = aws_sqs_queue.video_processing.arn
    events        = ["s3:ObjectCreated:*"]
    filter_suffix = ".mp4"
  }

  depends_on = [aws_sqs_queue_policy.video_processing]
}

# Bucket de artefatos de deploy: o CD do video-processor-converter publica aqui
# o zip do dlq-handler (dlq-handler/<sha>.zip e latest.zip), consumido pelo
# Terraform de Lambdas daquele repo.
resource "aws_s3_bucket" "artifacts" {
  bucket = "video-processor-artifacts-${var.environment}"

  tags = {
    Project     = "video-processor"
    Environment = var.environment
  }
}
