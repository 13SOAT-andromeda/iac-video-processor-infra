# S3 bucket names are globally unique; a bare "video-processor-bucket-${env}"
# collided with another AWS Academy Lab account during a prior apply. The
# converter's own Terraform (data.tf) already expects the account_id suffix.
data "aws_caller_identity" "current" {}

# Bucket de vídeos (contrato do video-processor-converter): uploads .mp4 disparam
# o tópico video_upload_events (messaging.tf); o worker grava o .zip de frames
# em processed/. O filtro por sufixo .mp4 evita que o .zip gerado re-dispare o
# worker (que também se protege via ErrNotRawKey).
resource "aws_s3_bucket" "video_processor" {
  bucket = "video-processor-bucket-${var.environment}-${data.aws_caller_identity.current.account_id}"

  tags = {
    Project     = "video-processor"
    Environment = var.environment
  }
}

# Notifica o tópico SNS video_upload_events em vez de ir direto pra fila do
# worker: o mesmo evento ObjectCreated precisa alimentar dois consumidores
# independentes (video_processing pro worker, video_upload_confirmation pro
# links-service — ver messaging.tf) e o S3 não permite duas filas SQS com o
# mesmo filtro de sufixo na mesma notificação (configuração ambígua). O SNS
# resolve isso com um único destino que faz o fan-out.
resource "aws_s3_bucket_notification" "video_processor" {
  bucket = aws_s3_bucket.video_processor.id

  topic {
    topic_arn     = aws_sns_topic.video_upload_events.arn
    events        = ["s3:ObjectCreated:*"]
    filter_suffix = ".mp4"
  }

  depends_on = [aws_sns_topic_policy.video_upload_events]
}

# Bucket de artefatos de deploy: o CD do video-processor-converter publica aqui
# o zip do dlq-handler (dlq-handler/<sha>.zip e latest.zip), consumido pelo
# Terraform de Lambdas daquele repo.
resource "aws_s3_bucket" "artifacts" {
  bucket = "video-processor-artifacts-${var.environment}-${data.aws_caller_identity.current.account_id}"

  tags = {
    Project     = "video-processor"
    Environment = var.environment
  }
}
