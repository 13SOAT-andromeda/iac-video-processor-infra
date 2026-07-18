resource "random_password" "jwt_signing_key" {
  length  = 64
  special = true
}

resource "aws_secretsmanager_secret" "jwt_signing_key" {
  name = "jwt-signing-key-${var.environment}"

  tags = {
    Project     = "video-processor"
    Environment = var.environment
  }
}

resource "aws_secretsmanager_secret_version" "jwt_signing_key" {
  secret_id     = aws_secretsmanager_secret.jwt_signing_key.id
  secret_string = random_password.jwt_signing_key.result
}
